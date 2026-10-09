defmodule CalleeWeb.CallChannel do
  @moduledoc """
  Signalling channel. Every open tab of a user joins `user:<type>:<id>`.

  Client -> server: call:start, call:accept, call:reject, call:hangup, signal
  Server -> client: call:incoming, call:ringing, call:accepted, call:ended, signal
  """
  use Phoenix.Channel
  alias Callee.{Calls, Turn, Push}

  @impl true
  def join(topic, _params, socket) do
    party = socket.assigns.party

    if topic == Calls.user_topic(party) do
      {type, id} = party
      Callee.Presence.track(party)
      active = Calls.active_call_for(party)

      # Opening the app (e.g. from the push) while being called: caller now hears ringing.
      with %{status: "ringing", callee: %{type: t, id: i}, call_id: cid} <- active,
           true <- {String.to_existing_atom(t), i} == party,
           do: Calls.mark_reached(cid)

      # Same tab coming back mid-call: re-attach so the grace timer is cancelled.
      dev = socket.assigns.device_id

      with %{status: "active", call_id: cid} <- active,
           true <- dev in [active[:caller_device], active[:callee_device]],
           do: Calls.rebind(cid, party, dev, self())

      {:ok,
       %{
         ice_servers: Turn.ice_servers("#{type}-#{id}"),
         active_call: active,
         joinable: joinable(party),
         media_mode: Callee.Recording.media_mode(),
         browser_records: Callee.Recording.browser_records?(),
         vapid_public_key: Push.public_key()
       }, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("call:start", %{"peer_id" => peer_id}, socket) do
    {type, _} = me = socket.assigns.party
    peer = {if(type == :tenant, do: :client, else: :tenant), to_int(peer_id)}

    case Calls.start_call(me, peer, socket.assigns.device_id, self()) do
      {:ok, call} -> {:reply, {:ok, %{call_id: call.id}}, socket}
      {:error, :busy, call} -> {:reply, {:error, %{reason: "busy", call_id: call.id}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # Tenant starts a group call: %{"group_id" => id} (saved group) or %{"client_ids" => [..]}
  def handle_in("group:start", params, %{assigns: %{party: {:tenant, _}}} = socket) do
    %{party: party, device_id: dev} = socket.assigns

    result =
      case params do
        %{"group_id" => gid} when not is_nil(gid) ->
          Calls.start_saved_group_call(party, gid, dev, self())

        %{"client_ids" => ids} when is_list(ids) ->
          Calls.start_group_call(party, ids, dev, self())

        _ ->
          {:error, :bad_request}
      end

    case result do
      {:ok, call} ->
        {:reply,
         {:ok,
          %{
            call_id: call.id,
            slots: Callee.Media.Room.slots_for(Application.get_env(:callee, :group_max, 50))
          }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("group:start", _, socket),
    do: {:reply, {:error, %{reason: "not_allowed"}}, socket}

  # Host rings someone again who missed / declined / left.
  def handle_in(
        "group:ring",
        %{"call_id" => id, "client_id" => cid},
        %{assigns: %{party: {:tenant, _}}} = socket
      ),
      do: respond(Calls.ring_again(id, socket.assigns.party, to_int(cid)), socket)

  def handle_in("call:accept", %{"call_id" => id}, socket) do
    case Calls.accept(id, socket.assigns.party, socket.assigns.device_id, self()) do
      {:ok, payload} -> {:reply, {:ok, payload}, socket}
      {:error, r} -> {:reply, {:error, %{reason: to_string(r)}}, socket}
    end
  end

  def handle_in("call:reject", %{"call_id" => id}, socket),
    do: respond(Calls.reject(id, socket.assigns.party), socket)

  def handle_in("call:hangup", %{"call_id" => id}, socket),
    do: respond(Calls.hangup(id, socket.assigns.party), socket)

  def handle_in("signal", %{"call_id" => id, "data" => data}, socket),
    do: respond(Calls.signal(id, socket.assigns.party, socket.assigns.device_id, data), socket)

  # Browser <-> server media signalling (RECORDING_MODE=server).
  def handle_in("media", %{"call_id" => id, "data" => data}, socket) do
    respond(
      Callee.Media.Session.signal(id, socket.assigns.party, socket.assigns.device_id, data),
      socket
    )
  end

  def handle_in("ice_servers", _, socket) do
    {type, id} = socket.assigns.party
    {:reply, {:ok, %{ice_servers: Turn.ice_servers("#{type}-#{id}")}}, socket}
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

  defp respond(:ok, socket), do: {:reply, :ok, socket}
  defp respond({:error, r}, socket), do: {:reply, {:error, %{reason: to_string(r)}}, socket}

  defp joinable({:client, _} = party) do
    for st <- Calls.joinable_group_calls(party),
        do: %{
          call_id: st.call_id,
          from: st.caller_view,
          name: st.group_name,
          count: st.count,
          others: st.others
        }
  end

  defp joinable(_), do: []

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)
end
