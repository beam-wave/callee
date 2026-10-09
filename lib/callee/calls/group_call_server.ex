defmodule Callee.Calls.GroupCallServer do
  @moduledoc """
  One process per group call (tenant host + several clients). Media always goes
  through `Callee.Media.Room`.

  Per-participant state:

      ringing --accept--> joined --hangup/disconnect--> left
         |--decline--> declined            ^
         |--45 s--> missed                 |  late join while the call is live
         `--(in another call) busy  -------'  (or host taps "ring again")

  The call stays open while the host is on it, so people who were unavailable
  can join later. It ends when the host hangs up, or after the host has been
  alone for GROUP_IDLE_MINUTES. Speaks the same protocol as `CallServer`
  (accept / reject / hangup / rebind / public_state).
  """
  use GenServer, restart: :temporary
  require Logger
  import Ecto.Query
  alias Callee.{Calls, Accounts, Push, Repo}
  alias Callee.Calls.Participant
  alias Callee.Media.Room

  @registry Callee.CallRegistry
  # duplicate keys: invitee -> live group calls they may (re)join
  @invites Callee.InviteRegistry

  def start_link(opts) do
    call = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, {:call, call.id}}})
  end

  ## Public helpers

  @doc "Live group calls `party` was invited to and isn't in right now."
  def joinable_for(party) do
    for {pid, _} <- Registry.lookup(@invites, party),
        st = safe_state(pid, party),
        st != nil,
        st.my_status not in ["joined", "ringing"],
        do: st
  end

  defp safe_state(pid, party) do
    GenServer.call(pid, {:public_state, party}, 2_000)
  catch
    :exit, _ -> nil
  end

  @doc "Host rings a participant again."
  def ring_again(call_id, host, cid) do
    GenServer.call({:via, Registry, {@registry, {:call, call_id}}}, {:ring, host, cid})
  catch
    :exit, _ -> {:error, :no_such_call}
  end

  defp ring_timeout, do: Application.get_env(:callee, :ring_timeout_ms, :timer.seconds(45))

  ## Init

  @impl true
  def init(opts) do
    call = Keyword.fetch!(opts, :call)
    host = Keyword.fetch!(opts, :host)
    {:tenant, tid} = host
    tenant = Accounts.get_tenant(tid)

    case Registry.register(@registry, {:party, host}, :host) do
      {:error, _} ->
        {:stop, {:busy, :caller}}

      {:ok, _} ->
        parts =
          for {cid, name} <- Keyword.fetch!(opts, :invitees), into: %{} do
            case Registry.register(@registry, {:party, {:client, cid}}, :participant) do
              {:ok, _} ->
                t = Process.send_after(self(), {:ring_timeout, cid}, ring_timeout())
                {cid, %{status: "ringing", name: name, device: nil, ref: nil, timer: t}}

              {:error, _} ->
                {cid, %{status: "busy", name: name, device: nil, ref: nil, timer: nil}}
            end
          end

        if Enum.all?(parts, fn {_, p} -> p.status == "busy" end) do
          Registry.unregister(@registry, {:party, host})
          {:stop, :all_busy}
        else
          now = DateTime.utc_now()

          Repo.insert_all(
            Participant,
            Enum.map(parts, fn {cid, p} ->
              %{
                call_id: call.id,
                client_id: cid,
                status: p.status,
                inserted_at: now,
                updated_at: now
              }
            end)
          )

          for {cid, _} <- parts, do: Registry.register(@invites, {:client, cid}, call.id)

          slots = Room.slots_for(Application.get_env(:callee, :group_max, 50))
          record? = Callee.Recording.mode() != "off"
          # host-led calls: the tenant is always heard by everyone
          {:ok, _} = Room.start(call: call, slots: slots, record: record?, pinned: "host")
          :ok = Room.add_leg(call.id, "host", host, Keyword.fetch!(opts, :device))

          if record?,
            do:
              Calls.create_recording(call, %{
                s3_key: "pending",
                content_type: "audio/ogg",
                status: "recording",
                mode: "server"
              })

          s = %{
            call: call,
            status: :ringing,
            host: host,
            host_device: Keyword.fetch!(opts, :device),
            host_ref: Process.monitor(Keyword.fetch!(opts, :pid)),
            host_view: %{type: "tenant", id: tid, name: tenant.name, subtitle: nil},
            group_name: Keyword.get(opts, :group_name),
            parts: parts,
            slots: slots,
            grace: %{},
            idle: nil,
            ever_joined: false
          }

          for {cid, %{status: "ringing"}} <- parts, do: ring(s, cid)
          Process.send_after(self(), :repush, Application.get_env(:callee, :repush_ms, 10_000))
          for {cid, %{status: "busy"}} <- parts, do: announce_live(s, cid)
          broadcast_roster(s)
          {:ok, touch_idle(s)}
        end
    end
  end

  ## Protocol

  @impl true
  def handle_call({:public_state, party}, _from, s), do: {:reply, public_state(s, party), s}
  def handle_call(:public_state, _from, s), do: {:reply, public_state(s, s.host), s}

  def handle_call({:accept, {:client, cid}, device, pid}, _from, s) do
    case s.parts[cid] do
      %{status: st} when st in ["missed", "declined", "left", "busy"] ->
        # Late join: unavailable when it rang, call still live.
        case Registry.register(@registry, {:party, {:client, cid}}, :participant) do
          {:ok, _} -> do_join(s, cid, device, pid)
          {:error, _} -> {:reply, {:error, :busy}, s}
        end

      %{status: "ringing"} ->
        do_join(s, cid, device, pid)

      _ ->
        {:reply, {:error, :cannot_accept}, s}
    end
  end

  def handle_call({:accept, _, _, _}, _from, s), do: {:reply, {:error, :cannot_accept}, s}

  def handle_call({:reject, {:client, cid}}, _from, s) do
    case s.parts[cid] do
      %{status: "ringing"} -> {:reply, :ok, touch_idle(resolve(s, cid, "declined"))}
      _ -> {:reply, {:error, :cannot_reject}, s}
    end
  end

  def handle_call({:reject, _}, _from, s), do: {:reply, {:error, :cannot_reject}, s}

  def handle_call({:hangup, party}, _from, %{host: party} = s) do
    Logger.info("group call #{s.call.id}: host ended it")
    end_call(s, if(s.ever_joined, do: "completed", else: "cancelled"), "host_ended", :ok)
  end

  def handle_call({:hangup, {:client, cid}}, _from, s) do
    case s.parts[cid] do
      %{status: "joined"} -> {:reply, :ok, touch_idle(leave(s, cid))}
      %{status: "ringing"} -> {:reply, :ok, touch_idle(resolve(s, cid, "declined"))}
      _ -> {:reply, {:error, :not_participant}, s}
    end
  end

  def handle_call({:hangup, _}, _from, s), do: {:reply, {:error, :not_participant}, s}

  def handle_call({:ring, host, cid}, _from, %{host: host} = s) do
    case s.parts[cid] do
      %{status: st} when st in ["missed", "declined", "left", "busy"] ->
        case Registry.register(@registry, {:party, {:client, cid}}, :participant) do
          {:ok, _} ->
            t = Process.send_after(self(), {:ring_timeout, cid}, ring_timeout())
            s = put_in(s.parts[cid], %{s.parts[cid] | status: "ringing", timer: t})
            persist(s.call.id, cid, %{status: "ringing"})
            ring(s, cid)
            broadcast_roster(s)
            {:reply, :ok, s}

          {:error, _} ->
            s = put_in(s.parts[cid].status, "busy")
            broadcast_roster(s)
            {:reply, {:error, :busy}, s}
        end

      _ ->
        {:reply, {:error, :cannot_ring}, s}
    end
  end

  def handle_call({:ring, _, _}, _from, s), do: {:reply, {:error, :not_host}, s}
  def handle_call({:signal, _, _, _}, _from, s), do: {:reply, {:error, :use_media}, s}
  def handle_call(:reached, _from, s), do: {:reply, :ok, s}

  def handle_call({:rebind, party, device, pid}, _from, s) do
    reply = {:ok, %{media: "server", group: true, slots: s.slots}}

    cond do
      party == s.host and device == s.host_device ->
        if s.host_ref, do: Process.demonitor(s.host_ref, [:flush])
        {:reply, reply, cancel_grace(%{s | host_ref: Process.monitor(pid)}, :host)}

      match?({:client, _}, party) and
          match?(%{status: "joined", device: ^device}, s.parts[elem(party, 1)]) ->
        cid = elem(party, 1)
        if ref = s.parts[cid].ref, do: Process.demonitor(ref, [:flush])
        {:reply, reply, cancel_grace(put_in(s.parts[cid].ref, Process.monitor(pid)), cid)}

      true ->
        {:reply, {:error, :not_participant}, s}
    end
  end

  ## Timers / monitors

  @impl true
  def handle_info({:ring_timeout, cid}, s) do
    case s.parts[cid] do
      %{status: "ringing"} ->
        s = resolve(s, cid, "missed")

        Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
          Push.notify_missed({:client, cid}, %{call_id: s.call.id, from: s.host_view})
        end)

        {:noreply, touch_idle(s)}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{host_ref: ref} = s) do
    Logger.info("group call #{s.call.id}: host connection dropped, waiting")
    {:noreply, start_grace(%{s | host_ref: nil}, :host)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, s) do
    case Enum.find(s.parts, fn {_, p} -> p.ref == ref end) do
      {cid, _} ->
        Logger.info("group call #{s.call.id}: client #{cid} connection dropped, waiting")
        {:noreply, start_grace(put_in(s.parts[cid].ref, nil), cid)}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info({:grace_expired, :host}, s) do
    if s.host_ref == nil, do: end_call(s, "completed", "host_disconnected"), else: {:noreply, s}
  end

  def handle_info({:grace_expired, cid}, s) do
    case s.parts[cid] do
      %{status: "joined", ref: nil} -> {:noreply, touch_idle(leave(s, cid))}
      _ -> {:noreply, s}
    end
  end

  def handle_info(:max_duration, s), do: end_call(s, "completed", "max_duration")

  # Keep alerting people whose phones are still ringing (see CallServer).
  def handle_info(:repush, s) do
    ringing = for {cid, %{status: "ringing"}} <- s.parts, do: cid

    for cid <- ringing do
      payload = %{
        call_id: s.call.id,
        from: s.host_view,
        group: %{others: map_size(s.parts) - 1, name: s.group_name}
      }

      label = s.group_name || "group call"

      Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
        Push.notify_incoming({:client, cid}, %{
          payload
          | from: %{s.host_view | name: "#{s.host_view.name} (#{label})"}
        })
      end)
    end

    Process.send_after(self(), :repush, Application.get_env(:callee, :repush_ms, 10_000))
    {:noreply, s}
  end

  # Host alone (nobody joined) for GROUP_IDLE_MINUTES.
  def handle_info(:idle, s) do
    if joined_count(s) == 0,
      do: end_call(s, if(s.ever_joined, do: "completed", else: "missed"), "idle"),
      else: {:noreply, %{s | idle: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  ## Helpers

  defp do_join(s, cid, device, pid) do
    p = s.parts[cid]
    if p.timer, do: Process.cancel_timer(p.timer)
    s = if s.status == :ringing, do: activate(s), else: s
    p = %{p | status: "joined", device: device, ref: Process.monitor(pid), timer: nil}
    s = %{s | parts: Map.put(s.parts, cid, p), ever_joined: true}
    persist(s.call.id, cid, %{status: "joined", joined_at: DateTime.utc_now(), left_at: nil})
    Logger.info("group call #{s.call.id}: client #{cid} joined")
    :ok = Room.add_leg(s.call.id, "c#{cid}", {:client, cid}, device)
    # other tabs of this client stop ringing / hide the join bar
    broadcast({:client, cid}, "call:accepted", %{
      call_id: s.call.id,
      callee_device: device,
      caller_device: nil,
      media: "server",
      group: true
    })

    broadcast({:client, cid}, "group:gone", %{call_id: s.call.id})
    broadcast_roster(s)
    {:reply, {:ok, %{media: "server", group: true, slots: s.slots}}, touch_idle(s)}
  end

  defp ring(s, cid) do
    payload = %{
      call_id: s.call.id,
      from: s.host_view,
      group: %{others: map_size(s.parts) - 1, name: s.group_name}
    }

    broadcast({:client, cid}, "call:incoming", payload)

    Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
      label = s.group_name || "group call"

      Push.notify_incoming({:client, cid}, %{
        payload
        | from: %{s.host_view | name: "#{s.host_view.name} (#{label})"}
      })
    end)
  end

  defp activate(s) do
    {:ok, call} = Calls.mark_active(s.call)

    Process.send_after(
      self(),
      :max_duration,
      Application.get_env(:callee, :max_call_hours, 8) * 3_600_000
    )

    %{s | call: call, status: :active}
  end

  # ringing participant -> declined / missed
  defp resolve(s, cid, status) do
    Logger.info("group call #{s.call.id}: client #{cid} #{status}")

    Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
      Push.notify_cancel({:client, cid}, s.call.id)
    end)

    p = s.parts[cid]
    if p.timer, do: Process.cancel_timer(p.timer)
    Registry.unregister_match(@registry, {:party, {:client, cid}}, :participant)
    persist(s.call.id, cid, %{status: status})

    broadcast({:client, cid}, "call:ended", %{
      call_id: s.call.id,
      status: if(status == "declined", do: "rejected", else: status),
      reason: status
    })

    s = put_in(s.parts[cid], %{p | status: status, timer: nil})
    broadcast_roster(s)
    announce_live(s, cid)
    s
  end

  defp leave(s, cid) do
    Logger.info("group call #{s.call.id}: client #{cid} left")
    Room.remove_leg(s.call.id, "c#{cid}")
    p = s.parts[cid]
    if p.ref, do: Process.demonitor(p.ref, [:flush])
    Registry.unregister_match(@registry, {:party, {:client, cid}}, :participant)
    persist(s.call.id, cid, %{status: "left", left_at: DateTime.utc_now()})

    broadcast({:client, cid}, "call:ended", %{
      call_id: s.call.id,
      status: "completed",
      reason: "left"
    })

    s = put_in(s.parts[cid], %{p | status: "left", ref: nil})
    broadcast_roster(s)
    announce_live(s, cid)
    s
  end

  defp joined_count(s), do: Enum.count(s.parts, fn {_, p} -> p.status == "joined" end)

  # The call stays open while the host is on it; only end after the host has
  # been alone for a while, so late joiners can still come in.
  defp touch_idle(s) do
    cond do
      joined_count(s) > 0 and s.idle ->
        Process.cancel_timer(s.idle)
        %{s | idle: nil}

      joined_count(s) == 0 and is_nil(s.idle) ->
        %{
          s
          | idle:
              Process.send_after(
                self(),
                :idle,
                Application.get_env(:callee, :group_idle_ms, 10 * 60_000)
              )
        }

      true ->
        s
    end
  end

  # Tell a client there's a live call they can still join.
  defp announce_live(s, cid) do
    broadcast({:client, cid}, "group:live", %{
      call_id: s.call.id,
      from: s.host_view,
      name: s.group_name,
      count: joined_count(s) + 1,
      others: map_size(s.parts) - 1
    })
  end

  defp end_call(s, status, reason, reply \\ nil) do
    now = DateTime.utc_now()

    for {cid, p} <- s.parts, p.status in ["ringing", "joined"] do
      persist(
        s.call.id,
        cid,
        if(p.status == "joined", do: %{status: "left", left_at: now}, else: %{status: "missed"})
      )
    end

    {:ok, call} = Calls.finish(s.call, status, reason)
    payload = %{call_id: call.id, status: status, reason: reason, duration: call.duration_seconds}
    broadcast(s.host, "call:ended", payload)

    for {cid, p} <- s.parts do
      if p.status == "ringing",
        do:
          Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
            Push.notify_cancel({:client, cid}, call.id)
          end)

      if p.status in ["ringing", "joined"], do: broadcast({:client, cid}, "call:ended", payload)
      broadcast({:client, cid}, "group:gone", %{call_id: call.id})
    end

    record? = Callee.Recording.mode() != "off" and s.ever_joined

    Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
      case Room.finish(call.id) do
        {:ok, %{files: files, dir: dir}} when record? ->
          Calls.RecordingProcessor.process_server(call, files, dir)

        {:ok, %{dir: dir}} ->
          File.rm_rf(dir)
          drop_recording(call.id)

        _ ->
          drop_recording(call.id)
      end
    end)

    Logger.info("group call #{call.id} ended status=#{status} reason=#{reason}")
    if reply, do: {:stop, :normal, reply, s}, else: {:stop, :normal, s}
  end

  defp drop_recording(call_id),
    do:
      Repo.delete_all(
        from r in Callee.Calls.Recording, where: r.call_id == ^call_id and r.status == "recording"
      )

  defp persist(call_id, cid, attrs) do
    from(p in Participant, where: p.call_id == ^call_id and p.client_id == ^cid)
    |> Repo.update_all(set: Map.to_list(Map.put(attrs, :updated_at, DateTime.utc_now())))

    Calls.notify_history(%{tenant_id: nil, client_id: cid, id: call_id})
  end

  defp start_grace(s, who) do
    t =
      Process.send_after(
        self(),
        {:grace_expired, who},
        Application.get_env(:callee, :reconnect_grace_ms, 45_000)
      )

    %{s | grace: Map.put(s.grace, who, t)}
  end

  defp cancel_grace(s, who) do
    case s.grace[who] do
      nil ->
        s

      t ->
        Process.cancel_timer(t)
        %{s | grace: Map.delete(s.grace, who)}
    end
  end

  defp roster(s) do
    [%{key: "host", name: s.host_view.name, status: "joined", host: true}] ++
      Enum.map(s.parts, fn {cid, p} ->
        %{key: "c#{cid}", name: p.name, status: p.status, host: false}
      end)
  end

  # Host and joined clients see live status; names only (no phone numbers).
  defp broadcast_roster(s) do
    payload = %{call_id: s.call.id, participants: roster(s)}
    broadcast(s.host, "group:roster", payload)

    for {cid, %{status: "joined"}} <- s.parts,
        do: broadcast({:client, cid}, "group:roster", payload)

    Calls.notify_history(%{tenant_id: elem(s.host, 1), client_id: nil, id: s.call.id})
  end

  defp public_state(s, party) do
    my =
      case party do
        {:client, cid} -> s.parts[cid] && s.parts[cid].status
        _ -> "joined"
      end

    %{
      kind: "group",
      call_id: s.call.id,
      status: if(party == s.host or my == "joined", do: "active", else: my),
      my_status: my,
      caller: %{type: "tenant", id: elem(s.host, 1)},
      callee: %{type: to_string(elem(party, 0)), id: elem(party, 1)},
      caller_device: s.host_device,
      callee_device:
        (match?({:client, _}, party) && s.parts[elem(party, 1)] && s.parts[elem(party, 1)].device) ||
          nil,
      caller_view: s.host_view,
      callee_view: %{type: "group", name: s.group_name || "Group call", subtitle: nil},
      group_name: s.group_name,
      participants: roster(s),
      count: joined_count(s) + 1,
      others: map_size(s.parts) - 1,
      slots: s.slots,
      reach: "ringing"
    }
  end

  defp broadcast(party, event, payload),
    do: CalleeWeb.Endpoint.broadcast(Calls.user_topic(party), event, payload)
end
