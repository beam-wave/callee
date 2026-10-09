defmodule Callee.Media.Session do
  @moduledoc """
  Server-side media for one call (used when RECORDING_MODE=server).

  Each participant's browser opens ONE WebRTC connection to this process instead
  of to the other person. We forward the Opus RTP of each side to the other
  (a tiny 2-party SFU, no transcoding) and append each side's audio to its own
  Ogg file on disk as it arrives. Memory use is constant regardless of call
  length; a 6 h call is ~2 x 15 MB on disk.

  Timing: Opus DTX (and packet loss) leaves gaps in the RTP stream. We fill them
  with Opus silence frames using RTP timestamps, and pad the start of each track
  from the moment the call was answered, so both tracks stay aligned for mixing.
  """
  use GenServer, restart: :temporary
  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate, MediaStreamTrack}
  alias ExWebRTC.Media.Ogg.Writer

  @registry Callee.CallRegistry
  # 20 ms CELT silence frame; 960 samples @ 48 kHz per frame.
  @silence <<0xF8, 0xFF, 0xFE>>
  @frame_ts 960
  @max_gap_frames 180_000

  ## API

  def start(opts) do
    DynamicSupervisor.start_child(Callee.MediaSupervisor, {__MODULE__, opts})
  end

  def start_link(opts) do
    call = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: via(call.id))
  end

  defp via(id), do: {:via, Registry, {@registry, {:media, id}}}

  @doc "Browser -> server signalling (offer / candidate) for the device's leg."
  def signal(call_id, party, device, data) do
    GenServer.call(via(call_id), {:signal, party, device, data})
  catch
    :exit, _ -> {:error, :no_media_session}
  end

  @doc "A participant reconnected on a new device id (e.g. page reload)."
  def stop_and_collect(call_id) do
    GenServer.call(via(call_id), :finish, 15_000)
  catch
    :exit, _ -> {:error, :no_media_session}
  end

  ## Server

  @impl true
  def init(opts) do
    call = Keyword.fetch!(opts, :call)
    dir = Path.join(Application.get_env(:callee, :recording_dir), call.id)
    File.mkdir_p!(dir)
    record? = Keyword.get(opts, :record, true)

    legs =
      for {role, party, device} <- Keyword.fetch!(opts, :legs), into: %{} do
        {role,
         %{
           party: party,
           device: device,
           pc: nil,
           out: nil,
           writer: nil,
           last_ts: nil,
           path: Path.join(dir, "#{role}.ogg")
         }}
      end

    {:ok,
     %{
       call: call,
       dir: dir,
       record?: record?,
       legs: legs,
       t0: System.monotonic_time(:millisecond),
       started_at: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_call({:signal, party, device, data}, _from, s) do
    case Enum.find(s.legs, fn {_r, l} -> l.party == party end) do
      nil ->
        {:reply, {:error, :not_participant}, s}

      {role, leg} ->
        # Same party may come back on a new tab/device after a reload.
        leg = if leg.device != device, do: reset_leg(leg, device), else: leg
        {reply, leg} = handle_signal(role, leg, data, s)
        {:reply, reply, put_in(s.legs[role], leg)}
    end
  end

  def handle_call(:finish, _from, s) do
    files =
      for {_role, leg} <- s.legs, leg.writer do
        Writer.close(leg.writer)
        leg.path
      end
      |> Enum.filter(&(File.exists?(&1) and File.stat!(&1).size > 200))

    for {_r, %{pc: pc}} <- s.legs, pc, do: PeerConnection.close(pc)
    {:stop, :normal, {:ok, %{files: files, dir: s.dir, started_at: s.started_at}}, s}
  end

  defp reset_leg(leg, device) do
    if leg.pc, do: PeerConnection.close(leg.pc)
    %{leg | device: device, pc: nil, out: nil}
  end

  defp handle_signal(role, leg, %{"type" => "offer", "sdp" => sdp}, s) do
    leg = ensure_pc(leg, s)

    :ok =
      PeerConnection.set_remote_description(
        leg.pc,
        SessionDescription.from_json(%{"type" => "offer", "sdp" => sdp})
      )

    leg =
      if leg.out do
        leg
      else
        out = MediaStreamTrack.new(:audio, [MediaStreamTrack.generate_stream_id()])
        {:ok, _sender} = PeerConnection.add_track(leg.pc, out)
        %{leg | out: out}
      end

    {:ok, answer} = PeerConnection.create_answer(leg.pc)
    :ok = PeerConnection.set_local_description(leg.pc, answer)
    push(leg, s, %{"type" => "answer", "sdp" => answer.sdp})
    Logger.debug("media #{s.call.id}: #{role} negotiated")
    {:ok, leg}
  rescue
    e ->
      Logger.error("media offer failed: #{Exception.message(e)}")
      {{:error, :bad_offer}, leg}
  end

  defp handle_signal(_role, %{pc: pc} = leg, %{"type" => "candidate", "candidate" => c}, _s)
       when not is_nil(pc) and is_map(c) do
    PeerConnection.add_ice_candidate(pc, ICECandidate.from_json(c))
    {:ok, leg}
  end

  defp handle_signal(_role, leg, _data, _s), do: {:ok, leg}

  defp ensure_pc(%{pc: nil} = leg, _s) do
    {:ok, pc} =
      PeerConnection.start_link(
        ice_port_range: port_range(),
        ice_ip_filter: fn ip -> ip != {127, 0, 0, 1} end,
        audio_codecs: [:opus],
        video_codecs: []
      )

    %{leg | pc: pc}
  end

  defp ensure_pc(leg, _s), do: leg

  defp port_range do
    case String.split(Application.get_env(:callee, :media_port_range, ""), "-") do
      [a, b] -> String.to_integer(a)..String.to_integer(b)
      _ -> [0]
    end
  end

  ## WebRTC events

  @impl true
  def handle_info({:ex_webrtc, pc, msg}, s) do
    case Enum.find(s.legs, fn {_r, l} -> l.pc == pc end) do
      nil -> {:noreply, s}
      {role, leg} -> {:noreply, on_pc(role, leg, msg, s)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp on_pc(_role, leg, {:ice_candidate, c}, s) do
    push(leg, s, %{"type" => "candidate", "candidate" => ICECandidate.to_json(c)})
    s
  end

  defp on_pc(role, _leg, {:rtp, _track_id, _rid, packet}, s) do
    # forward to the other leg
    {_other_role, other} = Enum.find(s.legs, fn {r, _} -> r != role end)
    if other.pc && other.out, do: PeerConnection.send_rtp(other.pc, other.out.id, packet)

    if s.record?, do: update_in(s.legs[role], &record(&1, packet, s)), else: s
  end

  defp on_pc(role, _leg, {:connection_state_change, st}, s) do
    Logger.info("media #{s.call.id}: #{role} #{st}")
    s
  end

  defp on_pc(_role, _leg, _msg, s), do: s

  ## Recording with gap filling

  defp record(%{writer: nil} = leg, packet, s) do
    {:ok, w} = Writer.open(leg.path)
    # pad from call answer to first packet so both tracks line up
    lead = div(System.monotonic_time(:millisecond) - s.t0, 20) |> min(@max_gap_frames)
    w = write_silence(w, lead)
    write(%{leg | writer: w}, packet)
  end

  defp record(leg, packet, _s) do
    delta = Bitwise.band(packet.timestamp - leg.last_ts, 0xFFFFFFFF)

    cond do
      # late / reordered / duplicate packet: drop (keeps file monotonic)
      delta == 0 or delta > 0x7FFFFFFF ->
        leg

      true ->
        missing =
          (div(delta + div(@frame_ts, 2), @frame_ts) - 1) |> max(0) |> min(@max_gap_frames)

        write(%{leg | writer: write_silence(leg.writer, missing)}, packet)
    end
  end

  defp write(leg, packet) do
    case Writer.write_packet(leg.writer, packet.payload) do
      {:ok, w} -> %{leg | writer: w, last_ts: packet.timestamp}
      _ -> %{leg | last_ts: packet.timestamp}
    end
  end

  defp write_silence(w, 0), do: w

  defp write_silence(w, n) do
    Enum.reduce(1..n, w, fn _, acc ->
      case Writer.write_packet(acc, @silence) do
        {:ok, a} -> a
        _ -> acc
      end
    end)
  end

  defp push(leg, s, data) do
    CalleeWeb.Endpoint.broadcast(Callee.Calls.user_topic(leg.party), "media", %{
      call_id: s.call.id,
      to_device: leg.device,
      data: data
    })
  end

  @impl true
  def terminate(_reason, s) do
    for {_r, leg} <- s.legs do
      if leg.writer, do: Writer.close(leg.writer)
      if leg.pc, do: PeerConnection.close(leg.pc)
    end

    :ok
  catch
    _, _ -> :ok
  end
end
