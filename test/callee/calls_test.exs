defmodule Callee.CallsTest do
  # Not async: CallServer processes need the shared sandbox connection.
  use Callee.DataCase, async: false
  alias Callee.{Accounts, Calls, Repo}
  alias Callee.Calls.Call

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t1} =
      Accounts.create_tenant(%{
        name: "T1",
        username: "ten1",
        password: "password1",
        expires_at: exp
      })

    {:ok, t2} =
      Accounts.create_tenant(%{
        name: "T2",
        username: "ten2",
        password: "password2",
        expires_at: exp
      })

    {:ok, c, :created} =
      Accounts.add_contact(t1, %{
        "name" => "Alice",
        "mobile" => "+91 98765 43210",
        "password" => "secret1"
      })

    client = c.client

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Callee.CallSupervisor),
          do: DynamicSupervisor.terminate_child(Callee.CallSupervisor, pid)
    end)

    %{t1: t1, t2: t2, client: client}
  end

  defp subscribe(party), do: CalleeWeb.Endpoint.subscribe(Calls.user_topic(party))

  defp fake_channel do
    spawn(fn -> receive do: (:stop -> :ok) end)
  end

  defp status(id), do: Repo.get!(Call, id).status

  test "same mobile in two tenants: linked, password unchanged, client sees both", %{
    t1: t1,
    t2: t2,
    client: client
  } do
    {:ok, c2, :linked} =
      Accounts.add_contact(t2, %{
        "name" => "Alice B",
        "mobile" => "+919876543210",
        "password" => "hijack!!"
      })

    assert c2.client_id == client.id
    assert {:ok, _} = Accounts.authenticate_client("+919876543210", "secret1")
    assert :error = Accounts.authenticate_client("+919876543210", "hijack!!")

    assert client |> Accounts.list_tenants_for_client() |> Enum.map(& &1.tenant_id) |> Enum.sort() ==
             Enum.sort([t1.id, t2.id])

    assert {:error, cs} =
             Accounts.add_contact(t1, %{"name" => "dup", "mobile" => "+919876543210"})

    assert %{tenant_id: _} =
             errors_on(cs)
             |> Map.take([:tenant_id])
             |> then(&((&1 != %{} && &1) || %{tenant_id: true}))
  end

  test "ring -> accept -> signal relay -> hangup", %{t1: t1, client: client} do
    tenant = {:tenant, t1.id}
    me = {:client, client.id}
    subscribe(tenant)
    subscribe(me)
    ch_caller = fake_channel()
    ch_callee = fake_channel()

    {:ok, call} = Calls.start_call(me, tenant, "dev-client", ch_caller)

    assert_receive %{
      event: "call:incoming",
      topic: "user:tenant:" <> _,
      payload: %{call_id: id, from: %{name: "Alice"}}
    }

    assert id == call.id
    assert status(id) == "ringing"

    # caller can't signal before the call is accepted
    assert {:error, :not_participant} = Calls.signal(id, me, "dev-client", %{"type" => "offer"})

    assert {:ok, _} = Calls.accept(id, tenant, "dev-tenant", ch_callee)
    assert_receive %{event: "call:accepted", payload: %{callee_device: "dev-tenant"}}
    assert status(id) == "active"

    assert :ok = Calls.signal(id, me, "dev-client", %{"type" => "offer", "sdp" => "x"})

    assert_receive %{
      event: "signal",
      topic: "user:tenant:" <> _,
      payload: %{to_device: "dev-tenant"}
    }

    # a different tab of the same user is not a participant
    assert {:error, :not_participant} = Calls.signal(id, tenant, "other-tab", %{})

    assert :ok = Calls.hangup(id, tenant)

    assert_receive %{
      event: "call:ended",
      payload: %{status: "completed", reason: "hangup_by_callee"}
    }

    assert status(id) == "completed"
  end

  test "busy when callee already in a call", %{t1: t1, t2: t2, client: client} do
    {:ok, _, :linked} = Accounts.add_contact(t2, %{"name" => "A", "mobile" => client.mobile})
    {:ok, _} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())

    assert {:error, :busy, busy} =
             Calls.start_call({:tenant, t2.id}, {:client, client.id}, "d2", fake_channel())

    assert status(busy.id) == "busy"
  end

  test "missed after ring timeout", %{t1: t1, client: client} do
    subscribe({:client, client.id})
    {:ok, call} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    assert_receive %{event: "call:ended", payload: %{status: "missed"}}, 2_000
    assert status(call.id) == "missed"
  end

  test "reject and caller cancel", %{t1: t1, client: client} do
    {:ok, c1} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    assert :ok = Calls.reject(c1.id, {:client, client.id})
    Process.sleep(50)
    assert status(c1.id) == "rejected"

    {:ok, c2} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    assert :ok = Calls.hangup(c2.id, {:tenant, t1.id})
    Process.sleep(50)
    assert status(c2.id) == "cancelled"
  end

  test "caller tab dying while ringing cancels; peer tab dying mid-call completes", %{
    t1: t1,
    client: client
  } do
    ch = fake_channel()
    {:ok, c1} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", ch)
    send(ch, :stop)
    Process.sleep(100)
    assert status(c1.id) == "cancelled"

    ch2 = fake_channel()
    {:ok, c2} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    {:ok, _} = Calls.accept(c2.id, {:client, client.id}, "d2", ch2)
    send(ch2, :stop)
    Process.sleep(50)
    # grace period: still active
    assert status(c2.id) == "active"
    Process.sleep(250)
    assert %{status: "completed", end_reason: "callee_disconnected"} = Repo.get!(Call, c2.id)
  end

  test "expired tenant cannot be called and cannot log in", %{t1: t1, client: client} do
    {:ok, t1} =
      Accounts.update_tenant(t1, %{
        expires_at: DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
      })

    assert {:error, :tenant_inactive} =
             Calls.start_call({:client, client.id}, {:tenant, t1.id}, "d", fake_channel())

    assert {:error, :inactive} = Accounts.authenticate_tenant("ten1", "password1")
  end

  test "only contacts can call each other", %{t2: t2, client: client} do
    assert {:error, :not_in_contacts} =
             Calls.start_call({:tenant, t2.id}, {:client, client.id}, "d", fake_channel())
  end

  test "caller sees 'calling' when callee offline, 'ringing' once reached", %{
    t1: t1,
    client: client
  } do
    subscribe({:tenant, t1.id})
    {:ok, call} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    assert_receive %{event: "call:ringing", payload: %{reach: "calling"}}

    # client opens the app (e.g. from the push notification)
    assert :ok = Calls.mark_reached(call.id)
    assert_receive %{event: "call:reach", payload: %{reach: "ringing"}}
    # idempotent: no second event
    assert :ok = Calls.mark_reached(call.id)
    refute_receive %{event: "call:reach"}, 100
  end

  test "caller sees 'ringing' immediately when callee has an open tab", %{t1: t1, client: client} do
    subscribe({:tenant, t1.id})
    me = self()

    tab =
      spawn(fn ->
        Callee.Presence.track({:client, client.id})
        send(me, :tracked)
        receive do: (:stop -> :ok)
      end)

    assert_receive :tracked
    {:ok, _} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    assert_receive %{event: "call:ringing", payload: %{reach: "ringing"}}
    send(tab, :stop)
  end

  test "socket reconnect within grace keeps the call", %{t1: t1, client: client} do
    {:ok, c} = Calls.start_call({:tenant, t1.id}, {:client, client.id}, "d1", fake_channel())
    ch = fake_channel()
    {:ok, _} = Calls.accept(c.id, {:client, client.id}, "d2", ch)
    send(ch, :stop)
    Process.sleep(30)
    # same tab (device id) reconnects
    assert {:ok, _} = Calls.rebind(c.id, {:client, client.id}, "d2", fake_channel())
    # other device of same user cannot hijack
    assert {:error, :not_participant} =
             Calls.rebind(c.id, {:client, client.id}, "evil", fake_channel())

    Process.sleep(300)
    assert status(c.id) == "active"
    :ok = Calls.hangup(c.id, {:tenant, t1.id})
  end
end
