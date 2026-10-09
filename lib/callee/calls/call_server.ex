defmodule Callee.Calls.CallServer do
  @moduledoc """
  One process per live call. Authoritative call state machine:

      ringing --accept--> active --hangup/disconnect--> completed
         |--reject--> rejected
         |--caller hangup--> cancelled
         |--ring timeout--> missed
         `--caller disconnect--> cancelled

  Both parties are registered in `Callee.CallRegistry` under `{:party, party}`
  (unique keys), which gives an atomic "busy" check.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Callee.{Calls, Accounts, Push}

  defp ring_timeout, do: Application.get_env(:callee, :ring_timeout_ms, :timer.seconds(45))
  @registry Callee.CallRegistry

  def start_link(opts) do
    call = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: via(call.id))
  end

  defp via(id), do: {:via, Registry, {@registry, {:call, id}}}

  defp call_server(id, msg) do
    GenServer.call(via(id), msg)
  catch
    :exit, _ -> {:error, :no_such_call}
  end

  def accept(id, party, device, pid), do: call_server(id, {:accept, party, device, pid})
  def reject(id, party), do: call_server(id, {:reject, party})
  def hangup(id, party), do: call_server(id, {:hangup, party})
  def signal(id, party, device, data), do: call_server(id, {:signal, party, device, data})

  @doc "Callee has a live tab or accepted push: switch caller from 'calling' to 'ringing'."
  def mark_reached(id), do: call_server(id, :reached)
  def rebind(id, party, device, pid), do: call_server(id, {:rebind, party, device, pid})

  @doc "Returns the public state of the call a party is in, if any."
  def active_call_for(party) do
    case Registry.lookup(@registry, {:party, party}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:public_state, party})
        catch
          :exit, _ -> nil
        end

      [] ->
        nil
    end
  end

  ## Server

  @impl true
  def init(opts) do
    call = Keyword.fetch!(opts, :call)
    caller = Keyword.fetch!(opts, :caller)
    callee = Keyword.fetch!(opts, :callee)

    with :ok <- register_party(caller, :caller),
         :ok <- register_party(callee, :callee) do
      ref = Process.monitor(Keyword.fetch!(opts, :pid))
      timer = Process.send_after(self(), :ring_timeout, ring_timeout())

      state = %{
        call: call,
        status: :ringing,
        caller: caller,
        callee: callee,
        caller_device: Keyword.fetch!(opts, :device),
        callee_device: nil,
        caller_ref: ref,
        callee_ref: nil,
        timer: timer,
        caller_view: view_of(caller, callee),
        callee_view: view_of(callee, caller)
      }

      # "ringing" = a callee device is actually alerted (open tab or push accepted).
      # "calling" = we're trying, but nothing has reached them yet.
      reach = if Callee.Presence.online?(callee), do: "ringing", else: "calling"
      state = Map.put(state, :reach, reach)

      # Ring every open tab of the callee + a Web Push for closed/background tabs.
      incoming = incoming_payload(state)
      broadcast(callee, "call:incoming", incoming)

      broadcast(caller, "call:ringing", %{
        call_id: call.id,
        device: state.caller_device,
        peer: state.callee_view,
        reach: reach
      })

      server = self()

      push_ring(server, callee, incoming)
      Process.send_after(self(), :repush, repush_ms())

      {:ok, state}
    else
      {:busy, who} -> {:stop, {:busy, who}}
    end
  end

  defp register_party(party, role) do
    case Registry.register(@registry, {:party, party}, role) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:busy, role}
    end
  end

  # How `party` is displayed to the other side.
  defp view_of({:tenant, tid}, {:client, _}) do
    t = Accounts.get_tenant(tid)
    %{type: "tenant", id: tid, name: t.name, subtitle: nil}
  end

  defp view_of({:client, cid}, {:tenant, tid}) do
    c = Accounts.get_client(cid)
    contact = Accounts.get_contact(tid, cid)
    %{type: "client", id: cid, name: (contact && contact.name) || c.mobile, subtitle: c.mobile}
  end

  defp incoming_payload(s), do: %{call_id: s.call.id, from: s.caller_view}

  @impl true
  def handle_call({:public_state, _party}, from, s), do: handle_call(:public_state, from, s)

  def handle_call(:public_state, _from, s) do
    {:reply,
     %{
       call_id: s.call.id,
       status: to_string(s.status),
       caller: party_json(s.caller),
       callee: party_json(s.callee),
       caller_device: s.caller_device,
       callee_device: s.callee_device,
       caller_view: s.caller_view,
       callee_view: s.callee_view,
       reach: s.reach
     }, s}
  end

  def handle_call({:accept, party, device, pid}, _from, %{status: :ringing, callee: party} = s) do
    Process.cancel_timer(s.timer)
    {:ok, call} = Calls.mark_active(s.call)
    ref = Process.monitor(pid)
    s = %{s | call: call, status: :active, callee_device: device, callee_ref: ref}

    Callee.Recording.on_active(call, [
      {:caller, s.caller, s.caller_device},
      {:callee, party, device}
    ])

    max_ms = Application.get_env(:callee, :max_call_hours, 8) * 3_600_000
    Process.send_after(self(), :max_duration, max_ms)

    payload = %{
      call_id: call.id,
      caller_device: s.caller_device,
      callee_device: device,
      media: Callee.Recording.media_mode(),
      browser_records: Callee.Recording.browser_records?()
    }

    broadcast(s.caller, "call:accepted", payload)
    broadcast(s.callee, "call:accepted", payload)
    {:reply, {:ok, payload}, s}
  end

  def handle_call(:reached, _from, s), do: {:reply, :ok, reached(s)}

  # A participant's tab reconnected its socket (phone woke up, network switch,
  # or page reload with the same per-tab device id) within the grace period.
  def handle_call({:rebind, party, device, pid}, _from, %{status: :active} = s) do
    role =
      cond do
        party == s.caller and device == s.caller_device -> :caller
        party == s.callee and device == s.callee_device -> :callee
        true -> nil
      end

    if role do
      ref_key = :"#{role}_ref"
      if old = Map.get(s, ref_key), do: Process.demonitor(old, [:flush])
      s = Map.put(s, ref_key, Process.monitor(pid))
      s = cancel_grace(s, role)
      broadcast(other(s, role), "call:peer", %{call_id: s.call.id, state: "back"})

      {:reply,
       {:ok,
        %{
          media: Callee.Recording.media_mode(),
          browser_records: Callee.Recording.browser_records?()
        }}, s}
    else
      {:reply, {:error, :not_participant}, s}
    end
  end

  def handle_call({:rebind, _, _, _}, _from, s), do: {:reply, {:error, :not_active}, s}

  def handle_call({:accept, _, _, _}, _from, s), do: {:reply, {:error, :cannot_accept}, s}

  def handle_call({:reject, party}, _from, %{status: :ringing, callee: party} = s),
    do: finish(s, "rejected", "rejected_by_callee", :ok)

  def handle_call({:reject, _}, _from, s), do: {:reply, {:error, :cannot_reject}, s}

  def handle_call({:hangup, party}, _from, %{status: :ringing, caller: party} = s),
    do: finish(s, "cancelled", "cancelled_by_caller", :ok)

  def handle_call({:hangup, party}, _from, %{status: :ringing, callee: party} = s),
    do: finish(s, "rejected", "rejected_by_callee", :ok)

  def handle_call({:hangup, party}, _from, %{status: :active} = s)
      when party in [s.caller, s.callee],
      do: finish(s, "completed", "hangup_by_#{role(s, party)}", :ok)

  def handle_call({:hangup, _}, _from, s), do: {:reply, {:error, :not_participant}, s}

  # Relay SDP / ICE between the two participating devices only.
  def handle_call({:signal, party, device, data}, _from, s) do
    cond do
      party == s.caller and device == s.caller_device and s.callee_device ->
        broadcast(s.callee, "signal", %{
          call_id: s.call.id,
          to_device: s.callee_device,
          data: data
        })

        {:reply, :ok, s}

      party == s.callee and device == s.callee_device ->
        broadcast(s.caller, "signal", %{
          call_id: s.call.id,
          to_device: s.caller_device,
          data: data
        })

        {:reply, :ok, s}

      true ->
        {:reply, {:error, :not_participant}, s}
    end
  end

  @impl true
  def handle_info(:reached, s), do: {:noreply, reached(s)}

  # Phones in the background only hear about calls via Web Push, and a single
  # notification is easy to miss. Re-alert every few seconds while ringing,
  # like a phone ring (same tag, so it replaces rather than stacks).
  def handle_info(:repush, %{status: :ringing} = s) do
    push_ring(self(), s.callee, incoming_payload(s))
    Process.send_after(self(), :repush, repush_ms())
    {:noreply, s}
  end

  def handle_info(:ring_timeout, %{status: :ringing} = s),
    do: finish(s, "missed", "no_answer")

  def handle_info({:DOWN, ref, :process, _, _}, %{caller_ref: ref, status: :ringing} = s),
    do: finish(s, "cancelled", "caller_disconnected")

  # Don't drop an answered call the moment a socket blips: phones sleep and
  # switch networks. Media keeps flowing; wait for the tab to come back.
  def handle_info({:DOWN, ref, :process, _, _}, %{status: :active} = s)
      when ref in [s.caller_ref, s.callee_ref] do
    role = if ref == s.caller_ref, do: :caller, else: :callee
    s = Map.put(s, :"#{role}_ref", nil)
    grace = Application.get_env(:callee, :reconnect_grace_ms, 45_000)
    t = Process.send_after(self(), {:grace_expired, role}, grace)
    broadcast(other(s, role), "call:peer", %{call_id: s.call.id, state: "reconnecting"})
    {:noreply, Map.update(s, :grace, %{role => t}, &Map.put(&1, role, t))}
  end

  def handle_info({:grace_expired, role}, %{status: :active} = s) do
    if Map.get(s, :"#{role}_ref") == nil,
      do: finish(s, "completed", "#{role}_disconnected"),
      else: {:noreply, s}
  end

  def handle_info(:max_duration, %{status: :active} = s),
    do: finish(s, "completed", "max_duration")

  def handle_info(_msg, s), do: {:noreply, s}

  defp finish(s, status, reason, reply \\ nil) do
    {:ok, call} = Calls.finish(s.call, status, reason)
    if s.status == :active, do: Callee.Recording.on_end(call)
    payload = %{call_id: call.id, status: status, reason: reason, duration: call.duration_seconds}
    broadcast(s.caller, "call:ended", payload)
    broadcast(s.callee, "call:ended", payload)

    if status == "missed" do
      Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
        Push.notify_missed(s.callee, %{call_id: call.id, from: s.caller_view})
      end)
    end

    Logger.info("call #{call.id} ended status=#{status} reason=#{reason}")

    if reply,
      do: {:stop, :normal, reply, s},
      else: {:stop, :normal, s}
  end

  defp reached(%{status: :ringing, reach: "calling"} = s) do
    broadcast(s.caller, "call:reach", %{call_id: s.call.id, reach: "ringing"})
    %{s | reach: "ringing"}
  end

  defp reached(s), do: s

  defp other(s, :caller), do: s.callee
  defp other(s, :callee), do: s.caller

  defp cancel_grace(s, role) do
    case get_in(s, [Access.key(:grace, %{}), role]) do
      nil ->
        s

      t ->
        Process.cancel_timer(t)
        update_in(s, [:grace], &Map.delete(&1, role))
    end
  end

  defp repush_ms, do: Application.get_env(:callee, :repush_ms, 10_000)

  defp push_ring(server, callee, payload) do
    Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
      case Push.notify_incoming(callee, payload) do
        {:ok, n} when n > 0 -> send(server, :reached)
        _ -> :ok
      end
    end)
  end

  defp role(s, party), do: if(party == s.caller, do: "caller", else: "callee")
  defp party_json({t, id}), do: %{type: to_string(t), id: id}

  defp broadcast(party, event, payload),
    do: CalleeWeb.Endpoint.broadcast(Calls.user_topic(party), event, payload)
end
