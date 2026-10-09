defmodule Callee.GroupCallsTest do
  use Callee.DataCase, async: false
  alias Callee.{Accounts, Calls, Repo}
  alias Callee.Calls.{Call, Participant}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    dir = Path.join(System.tmp_dir!(), "callee-grp-#{System.unique_integer([:positive])}")
    Application.put_env(:callee, :recording_dir, dir)
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Host Org",
        username: "hostorg",
        password: "password1",
        expires_at: exp
      })

    clients =
      for i <- 1..4 do
        {:ok, c, _} =
          Accounts.add_contact(t, %{
            "name" => "P#{i}",
            "mobile" => "720000000#{i}",
            "password" => "pw1234"
          })

        c.client_id
      end

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Callee.CallSupervisor),
          do: DynamicSupervisor.terminate_child(Callee.CallSupervisor, pid)

      File.rm_rf(dir)
    end)

    %{t: t, clients: clients, host: {:tenant, t.id}}
  end

  defp ch, do: spawn(fn -> receive do: (:stop -> :ok) end)

  defp part_status(call_id, cid),
    do: Repo.get_by!(Participant, call_id: call_id, client_id: cid).status

  test "join, decline, ring timeout, then last leaver ends the call", %{
    host: host,
    clients: [a, b, c | _]
  } do
    CalleeWeb.Endpoint.subscribe(Calls.user_topic(host))
    CalleeWeb.Endpoint.subscribe(Calls.user_topic({:client, a}))
    {:ok, call} = Calls.start_group_call(host, [a, b, c], "host-dev", ch())

    assert_receive %{
      event: "call:incoming",
      payload: %{group: %{others: 2}, from: %{name: "Host Org"}}
    }

    assert_receive %{event: "group:roster", payload: %{participants: roster}}
    assert length(roster) == 4

    assert {:ok, %{group: true, slots: _}} = Calls.accept(call.id, {:client, a}, "a-dev", ch())
    assert Repo.get!(Call, call.id).status == "active"
    assert :ok = Calls.reject(call.id, {:client, b})
    assert part_status(call.id, b) == "declined"

    # c never answers -> missed after ring timeout (300 ms in test)
    Process.sleep(450)
    assert part_status(call.id, c) == "missed"
    assert Repo.get!(Call, call.id).status == "active"

    # a leaves -> host alone -> call stays open for late joiners, then idles out
    assert :ok = Calls.hangup(call.id, {:client, a})
    Process.sleep(50)
    assert Repo.get!(Call, call.id).status == "active"
    assert part_status(call.id, a) == "left"
    Process.sleep(400)
    assert %{status: "completed", end_reason: "idle"} = Repo.get!(Call, call.id)
    assert_receive %{event: "call:ended", topic: "user:tenant:" <> _}
  end

  test "host ending ends it for everyone; ringing ones become missed", %{
    host: host,
    clients: [a, b | _]
  } do
    {:ok, call} = Calls.start_group_call(host, [a, b], "host-dev", ch())
    {:ok, _} = Calls.accept(call.id, {:client, a}, "a-dev", ch())
    CalleeWeb.Endpoint.subscribe(Calls.user_topic({:client, a}))
    :ok = Calls.hangup(call.id, host)
    assert_receive %{event: "call:ended", payload: %{reason: "host_ended"}}
    Process.sleep(50)
    assert part_status(call.id, a) == "left"
    assert part_status(call.id, b) == "missed"
  end

  test "nobody answers -> missed; busy members are skipped", %{
    host: host,
    t: t,
    clients: [a, b, c | _]
  } do
    # a is busy in a direct call
    {:ok, _} = Calls.start_call({:tenant, t.id}, {:client, a}, "x", ch())
    # host itself is now busy too; use a second tenant as host
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t2} =
      Accounts.create_tenant(%{
        name: "Org2",
        username: "org2grp",
        password: "password1",
        expires_at: exp
      })

    for cid <- [a, b, c],
        do:
          Accounts.add_contact(t2, %{
            "name" => "x#{cid}",
            "mobile" => Accounts.get_client(cid).mobile
          })

    {:ok, call} = Calls.start_group_call({:tenant, t2.id}, [a, b, c], "h2", ch())
    assert part_status(call.id, a) == "busy"
    Process.sleep(900)
    assert %{status: "missed", end_reason: "idle"} = Repo.get!(Call, call.id)
    _ = host
  end

  test "validation: group size and address book", %{host: host, clients: [a | _]} do
    assert {:error, :bad_group_size} = Calls.start_group_call(host, [a], "d", ch())
    assert {:error, :not_in_contacts} = Calls.start_group_call(host, [a, 999_999], "d", ch())
  end

  test "group calls appear in tenant and client history with filters", %{
    t: t,
    host: host,
    clients: [a, b | _]
  } do
    {:ok, call} = Calls.start_group_call(host, [a, b], "host-dev", ch())
    :ok = Calls.reject(call.id, {:client, a})
    :ok = Calls.hangup(call.id, host)
    Process.sleep(50)

    assert Calls.paginate_calls_for_tenant(t.id, %{"filter" => "group"}).total == 1
    assert Calls.paginate_calls_for_tenant(t.id, %{"q" => "P2"}).total == 1
    assert Calls.paginate_calls_for_client(a, %{}).total == 1
    assert Calls.paginate_calls_for_client(a, %{"filter" => "missed"}).total == 1
    assert Calls.paginate_calls_for_client(b, %{"filter" => "missed"}).total == 1
    assert Calls.missed_count(:client, b) == 1
  end

  test "client leaves, then host ends -> reason host_ended", %{host: host, clients: [a, b | _]} do
    {:ok, call} = Calls.start_group_call(host, [a, b], "host-dev", ch())
    {:ok, _} = Calls.accept(call.id, {:client, a}, "a-dev", ch())
    {:ok, _} = Calls.accept(call.id, {:client, b}, "b-dev", ch())
    :ok = Calls.hangup(call.id, {:client, b})
    assert Repo.get!(Call, call.id).status == "active"
    :ok = Calls.hangup(call.id, host)
    Process.sleep(50)
    assert %{status: "completed", end_reason: "host_ended"} = Repo.get!(Call, call.id)
  end

  test "someone who missed it can join later while the call is live", %{
    host: host,
    clients: [a, b | _]
  } do
    CalleeWeb.Endpoint.subscribe(Calls.user_topic({:client, b}))
    {:ok, call} = Calls.start_group_call(host, [a, b], "host-dev", ch())
    {:ok, _} = Calls.accept(call.id, {:client, a}, "a-dev", ch())
    Process.sleep(400)
    assert part_status(call.id, b) == "missed"
    assert_receive %{event: "group:live", payload: %{call_id: id}} when id == call.id

    # b shows up later and sees the call as joinable
    assert [%{call_id: ^id, my_status: "missed"}] = Calls.joinable_group_calls({:client, b})
    assert {:ok, %{group: true}} = Calls.accept(call.id, {:client, b}, "b-dev", ch())
    assert part_status(call.id, b) == "joined"
    assert Calls.joinable_group_calls({:client, b}) == []

    # leave and rejoin
    :ok = Calls.hangup(call.id, {:client, b})
    assert {:ok, _} = Calls.accept(call.id, {:client, b}, "b-dev2", ch())
    assert part_status(call.id, b) == "joined"
    :ok = Calls.hangup(call.id, host)
  end

  test "host can ring a participant again", %{host: host, clients: [a, b | _]} do
    {:ok, call} = Calls.start_group_call(host, [a, b], "host-dev", ch())
    :ok = Calls.reject(call.id, {:client, b})
    CalleeWeb.Endpoint.subscribe(Calls.user_topic({:client, b}))
    assert :ok = Calls.ring_again(call.id, host, b)
    assert_receive %{event: "call:incoming", payload: %{call_id: id}} when id == call.id
    assert part_status(call.id, b) == "ringing"
    # only the host may do this
    assert {:error, :not_host} = Calls.ring_again(call.id, {:client, a}, b)
    :ok = Calls.hangup(call.id, host)
  end

  test "saved groups: create, call, history shows the group", %{
    t: t,
    host: host,
    clients: [a, b, c | _]
  } do
    assert {:error, cs} = Callee.Groups.save(t.id, %{"name" => "Solo", "client_ids" => [a]})
    assert %{members: _} = errors_on(cs)
    {:ok, g} = Callee.Groups.save(t.id, %{"name" => "Team A", "client_ids" => [a, b, c]})
    assert {:error, _} = Callee.Groups.save(t.id, %{"name" => "Team A", "client_ids" => [a, b]})
    {:ok, g} = Callee.Groups.save(t.id, %{"name" => "Team A", "client_ids" => [a, b]}, g)
    assert length(Callee.Groups.members_with_names(g)) == 2

    CalleeWeb.Endpoint.subscribe(Calls.user_topic({:client, a}))
    {:ok, call} = Calls.start_saved_group_call(host, g.id, "host-dev", ch())
    assert_receive %{event: "call:incoming", payload: %{group: %{name: "Team A"}}}
    assert Repo.get!(Call, call.id).group_id == g.id
    :ok = Calls.hangup(call.id, host)
  end
end
