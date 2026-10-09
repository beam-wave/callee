defmodule Callee.Media.Room do
  @moduledoc """
  Server-side media for a group call: an audio SFU with **active-speaker
  forwarding**, so groups of 20, 50+ work on phones.

  * Every participant opens ONE WebRTC connection with `slots` receive lines
    (default 4, `SPEAKER_SLOTS`). Lines are created up front, so joins, leaves and
    speaker changes never need renegotiation.
  * Browsers tag each Opus packet with its loudness (RFC 6464
    `ssrc-audio-level` header extension). Every #{250} ms we pick the loudest
    recent speakers and forward only them into each listener's slots (never
    their own voice). Small groups (≤ slots + 1 people) simply hear everyone.
  * When a slot switches to a different speaker we rewrite RTP sequence numbers
    and timestamps so the browser's jitter buffer sees one continuous stream.
  * No audio is decoded on the server. Each participant's audio is still
    appended to its own Ogg file (gap-filled, padded from room start) so the
    recording contains everyone, not just the forwarded speakers.

  The browser learns `mid -> participant` via "group:slots" for its UI.
  """
  use GenServer, restart: :temporary
  require Logger

  alias ExWebRTC.{PeerConnection, SessionDescription, ICECandidate, MediaStreamTrack}
  alias ExWebRTC.Media.Ogg.Writer

  @registry Callee.CallRegistry
  @silence <<0xF8, 0xFF, 0xFE>>
  @frame_ts 960
  @max_gap_frames 180_000
  @level_uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  @select_every 250
  # a speaker stays "recent" this long after their last voiced packet
  @active_ms 1_500
  # loudness bonus for current speakers so slots don't flap
  @stickiness 6

  ## API

  @doc "Receive lines per participant for a group of `max` people."
  def slots_for(max), do: min(max - 1, Application.get_env(:callee, :speaker_slots, 4))

  def start(opts), do: DynamicSupervisor.start_child(Callee.MediaSupervisor, {__MODULE__, opts})

  def start_link(opts) do
    call = Keyword.fetch!(opts, :call)
    GenServer.start_link(__MODULE__, opts, name: via(call.id))
  end

  defp via(id), do: {:via, Registry, {@registry, {:media, id}}}

  defp call(id, msg, timeout \\ 5_000) do
    GenServer.call(via(id), msg, timeout)
  catch
    :exit, _ -> {:error, :no_room}
  end

  def add_leg(id, key, party, device), do: call(id, {:add_leg, key, party, device})
  def remove_leg(id, key), do: call(id, {:remove_leg, key})
  def signal(id, party, device, data), do: call(id, {:signal, party, device, data})
  def finish(id), do: call(id, :finish, 30_000)

  ## Server

  @impl true
  def init(opts) do
    call = Keyword.fetch!(opts, :call)
    dir = Path.join(Application.get_env(:callee, :recording_dir), call.id)
    File.mkdir_p!(dir)
    Process.send_after(self(), :select, @select_every)

    {:ok,
     %{
       call: call,
       dir: dir,
       record?: Keyword.get(opts, :record, true),
       slots: Keyword.fetch!(opts, :slots),
       # always forwarded to everyone else, on slot 0 (the tenant/host)
       pinned: Keyword.get(opts, :pinned),
       legs: %{},
       files: [],
       t0: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:add_leg, key, party, device}, _from, s) do
    s =
      case s.legs[key] do
        nil ->
          leg = %{
            key: key,
            party: party,
            device: device,
            pc: nil,
            outs: [],
            mids: %{},
            # other_key => slot currently forwarded to this listener
            assign: %{},
            # slot => %{src, seq_off, ts_off, last_seq, last_ts, last_at}
            out: %{},
            level_id: nil,
            loud: 0.0,
            last_voice: nil,
            writer: nil,
            last_ts: nil,
            path: Path.join(s.dir, "#{key}-#{System.unique_integer([:positive])}.ogg")
          }

          s = put_in(s.legs[key], leg)

          # fill free slots both ways (enough for small groups; big groups get
          # filled by speaker selection as people talk)
          # pinned speaker (host) first, so it always gets a line
          others = Map.keys(s.legs) -- [key]
          others = Enum.sort_by(others, &(&1 != s.pinned))

          Enum.reduce(others, s, fn other, acc ->
            acc
            |> update_in([:legs, other], &assign_free(&1, key, acc.slots))
            |> update_in([:legs, key], &assign_free(&1, other, acc.slots))
          end)

        existing ->
          put_in(s.legs[key], reset_leg(existing, device))
      end

    push_all_slots(s)
    {:reply, :ok, s}
  end

  def handle_call({:remove_leg, key}, _from, s) do
    case Map.pop(s.legs, key) do
      {nil, _} ->
        {:reply, :ok, s}

      {leg, legs} ->
        if leg.pc, do: PeerConnection.close(leg.pc)

        files =
          if leg.writer, do: (Writer.close(leg.writer) && [leg.path]) ++ s.files, else: s.files

        legs = Map.new(legs, fn {k, l} -> {k, %{l | assign: Map.delete(l.assign, key)}} end)
        s = %{s | legs: legs, files: files}
        push_all_slots(s)
        {:reply, :ok, s}
    end
  end

  def handle_call({:signal, party, device, data}, _from, s) do
    case Enum.find(s.legs, fn {_k, l} -> l.party == party end) do
      nil ->
        {:reply, {:error, :not_participant}, s}

      {key, leg} ->
        leg = if leg.device != device, do: reset_leg(leg, device), else: leg
        {reply, leg} = handle_signal(leg, data, s)
        s = put_in(s.legs[key], leg)
        if match?(%{"type" => "offer"}, data), do: push_slots(leg, s)
        {:reply, reply, s}
    end
  end

  def handle_call(:finish, _from, s) do
    live =
      for {_k, leg} <- s.legs do
        if leg.pc, do: PeerConnection.close(leg.pc)
        if leg.writer, do: Writer.close(leg.writer) && leg.path
      end

    files =
      (s.files ++ live)
      |> Enum.filter(&(is_binary(&1) and File.exists?(&1) and File.stat!(&1).size > 200))

    {:stop, :normal, {:ok, %{files: files, dir: s.dir}}, %{s | legs: %{}}}
  end

  defp assign_free(leg, other_key, slots) do
    used = Map.values(leg.assign)

    case Enum.find(0..(slots - 1), &(&1 not in used)) do
      nil -> leg
      slot -> %{leg | assign: Map.put(leg.assign, other_key, slot)}
    end
  end

  defp reset_leg(leg, device) do
    if leg.pc, do: PeerConnection.close(leg.pc)
    %{leg | device: device, pc: nil, outs: [], mids: %{}, out: %{}, level_id: nil}
  end

  ## Signalling

  defp handle_signal(leg, %{"type" => "offer", "sdp" => sdp}, s) do
    leg = if leg.pc, do: leg, else: %{leg | pc: start_pc()}

    :ok =
      PeerConnection.set_remote_description(
        leg.pc,
        SessionDescription.from_json(%{"type" => "offer", "sdp" => sdp})
      )

    leg =
      if leg.outs == [] do
        outs =
          for _ <- 1..s.slots do
            t = MediaStreamTrack.new(:audio, [MediaStreamTrack.generate_stream_id()])
            {:ok, _} = PeerConnection.add_track(leg.pc, t)
            t
          end

        %{leg | outs: outs, out: %{}}
      else
        leg
      end

    {:ok, answer} = PeerConnection.create_answer(leg.pc)
    :ok = PeerConnection.set_local_description(leg.pc, answer)

    by_track =
      Map.new(PeerConnection.get_transceivers(leg.pc), fn tr ->
        {tr.sender.track && tr.sender.track.id, tr.mid}
      end)

    mids = leg.outs |> Enum.with_index() |> Map.new(fn {t, i} -> {i, by_track[t.id]} end)

    level_id =
      case Regex.run(~r/a=extmap:(\d+)(?:\/\w+)? #{Regex.escape(@level_uri)}/, answer.sdp) do
        [_, id] -> String.to_integer(id)
        _ -> nil
      end

    push(leg, s, "media", %{"type" => "answer", "sdp" => answer.sdp})
    {:ok, %{leg | mids: mids, level_id: level_id}}
  rescue
    e ->
      Logger.error("room offer failed: #{Exception.message(e)}")
      {{:error, :bad_offer}, leg}
  end

  defp handle_signal(%{pc: pc} = leg, %{"type" => "candidate", "candidate" => c}, _s)
       when not is_nil(pc) and is_map(c) do
    PeerConnection.add_ice_candidate(pc, ICECandidate.from_json(c))
    {:ok, leg}
  end

  defp handle_signal(leg, _, _), do: {:ok, leg}

  defp start_pc do
    range =
      case String.split(Application.get_env(:callee, :media_port_range, ""), "-") do
        [a, b] -> String.to_integer(a)..String.to_integer(b)
        _ -> [0]
      end

    {:ok, pc} =
      PeerConnection.start_link(
        ice_port_range: range,
        ice_ip_filter: fn ip -> ip != {127, 0, 0, 1} end,
        audio_codecs: [:opus],
        video_codecs: [],
        rtp_header_extensions:
          ExWebRTC.PeerConnection.Configuration.default_rtp_header_extensions() ++
            [%{type: :audio, uri: @level_uri}]
      )

    pc
  end

  ## Media

  @impl true
  def handle_info({:ex_webrtc, pc, msg}, s) do
    case Enum.find(s.legs, fn {_k, l} -> l.pc == pc end) do
      nil -> {:noreply, s}
      {key, leg} -> {:noreply, on_pc(key, leg, msg, s)}
    end
  end

  def handle_info(:select, s) do
    Process.send_after(self(), :select, @select_every)
    {:noreply, select_speakers(s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp on_pc(_key, leg, {:ice_candidate, c}, s) do
    push(leg, s, "media", %{"type" => "candidate", "candidate" => ICECandidate.to_json(c)})
    s
  end

  defp on_pc(key, leg, {:rtp, _tid, _rid, packet}, s) do
    now = System.monotonic_time(:millisecond)
    s = put_in(s.legs[key], measure(leg, packet, now))

    # forward to listeners that currently have this speaker in a slot
    legs =
      Enum.reduce(s.legs, s.legs, fn
        {k, l}, acc when k != key and l.pc != nil and l.outs != [] ->
          case l.assign[key] do
            nil -> acc
            slot -> Map.put(acc, k, forward(l, slot, key, packet, now))
          end

        _, acc ->
          acc
      end)

    s = %{s | legs: legs}
    if s.record?, do: update_in(s.legs[key], &record(&1, packet, s)), else: s
  end

  defp on_pc(key, _leg, {:connection_state_change, st}, s) do
    Logger.info("room #{s.call.id}: #{key} #{st}")
    s
  end

  defp on_pc(_, _, _, s), do: s

  # Loudness: RFC 6464 level (0 = loudest .. 127 = silence) when the browser
  # sends it; otherwise fall back to Opus packet size (DTX/silence is tiny).
  defp measure(leg, packet, now) do
    {loud, voiced} =
      with id when is_integer(id) <- leg.level_id,
           %ExRTP.Packet.Extension{} = ext <-
             ExRTP.Packet.fetch_extension(packet, id) |> ok_or_nil(),
           {:ok, %{level: level, voice: voice}} <- ExRTP.Packet.Extension.AudioLevel.from_raw(ext) do
        {127 - level, voice or level < 50}
      else
        _ -> {min(byte_size(packet.payload), 127), byte_size(packet.payload) > 20}
      end

    %{
      leg
      | loud: leg.loud * 0.8 + loud * 0.2,
        last_voice: if(voiced, do: now, else: leg.last_voice)
    }
  end

  defp ok_or_nil({:ok, v}), do: v
  defp ok_or_nil(_), do: nil

  # Keep each slot one continuous RTP stream across speaker switches.
  defp forward(l, slot, src, packet, now) do
    o = l.out[slot]

    o =
      cond do
        o == nil ->
          %{src: src, seq_off: 0, ts_off: 0, last_seq: nil, last_ts: nil, last_at: now}

        o.src == src ->
          o

        true ->
          gap_ts = max(@frame_ts, (now - o.last_at) * 48)

          %{
            o
            | src: src,
              seq_off: Bitwise.band(o.last_seq + 1 - packet.sequence_number, 0xFFFF),
              ts_off: Bitwise.band(o.last_ts + gap_ts - packet.timestamp, 0xFFFFFFFF)
          }
      end

    seq = Bitwise.band(packet.sequence_number + o.seq_off, 0xFFFF)
    ts = Bitwise.band(packet.timestamp + o.ts_off, 0xFFFFFFFF)

    PeerConnection.send_rtp(l.pc, Enum.at(l.outs, slot).id, %{
      packet
      | sequence_number: seq,
        timestamp: ts
    })

    %{l | out: Map.put(l.out, slot, %{o | last_seq: seq, last_ts: ts, last_at: now})}
  end

  ## Active-speaker selection

  defp select_speakers(%{legs: legs} = s) when map_size(legs) <= 2, do: s

  defp select_speakers(s) do
    now = System.monotonic_time(:millisecond)

    active =
      for {k, l} <- s.legs,
          l.last_voice && now - l.last_voice < @active_ms,
          into: %{},
          do: {k, l.loud}

    legs =
      Map.new(s.legs, fn {k, l} ->
        {k, reassign(l, active |> Map.delete(k) |> Map.delete(s.pinned), s.slots, s.pinned)}
      end)

    new_s = %{s | legs: legs}
    for {k, l} <- legs, l.assign != s.legs[k].assign, do: push_slots(l, new_s)
    new_s
  end

  # Keep current speakers (with a stickiness bonus); bring loud new speakers
  # into free slots or replace the quietest current one.
  defp reassign(l, active, slots, pinned) do
    # the pinned host keeps its line on every listener; others compete for the rest
    slots = if pinned && Map.has_key?(l.assign, pinned), do: slots - 1, else: slots

    if map_size(active) == 0 do
      l
    else
      scored =
        Map.new(active, fn {k, loud} ->
          {k, loud + if(Map.has_key?(l.assign, k), do: @stickiness, else: 0)}
        end)

      wanted =
        scored |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(slots) |> Enum.map(&elem(&1, 0))

      newcomers = Enum.reject(wanted, &Map.has_key?(l.assign, &1))

      Enum.reduce(newcomers, l, fn k, acc ->
        used = Map.values(acc.assign)

        total = if pinned && Map.has_key?(acc.assign, pinned), do: slots + 1, else: slots

        case Enum.find(0..(total - 1), &(&1 not in used)) do
          nil ->
            # evict the assigned speaker that isn't wanted (quietest first)
            victim =
              acc.assign
              |> Map.keys()
              |> Enum.reject(&(&1 in wanted or &1 == pinned))
              |> Enum.min_by(&Map.get(scored, &1, -1), fn -> nil end)

            if victim,
              do: %{
                acc
                | assign: acc.assign |> Map.delete(victim) |> Map.put(k, acc.assign[victim])
              },
              else: acc

          slot ->
            %{acc | assign: Map.put(acc.assign, k, slot)}
        end
      end)
    end
  end

  ## Recording

  defp record(%{writer: nil} = leg, packet, s) do
    {:ok, w} = Writer.open(leg.path)
    lead = div(System.monotonic_time(:millisecond) - s.t0, 20) |> min(@max_gap_frames)
    write(%{leg | writer: silence(w, lead)}, packet)
  end

  defp record(leg, packet, _s) do
    delta = Bitwise.band(packet.timestamp - leg.last_ts, 0xFFFFFFFF)

    if delta == 0 or delta > 0x7FFFFFFF do
      leg
    else
      missing = (div(delta + div(@frame_ts, 2), @frame_ts) - 1) |> max(0) |> min(@max_gap_frames)
      write(%{leg | writer: silence(leg.writer, missing)}, packet)
    end
  end

  defp write(leg, packet) do
    case Writer.write_packet(leg.writer, packet.payload) do
      {:ok, w} -> %{leg | writer: w, last_ts: packet.timestamp}
      _ -> %{leg | last_ts: packet.timestamp}
    end
  end

  defp silence(w, 0), do: w

  defp silence(w, n) do
    Enum.reduce(1..n, w, fn _, acc ->
      case Writer.write_packet(acc, @silence) do
        {:ok, a} -> a
        _ -> acc
      end
    end)
  end

  ## Browser notifications

  defp push_all_slots(s), do: Enum.each(s.legs, fn {_k, l} -> push_slots(l, s) end)

  defp push_slots(%{mids: mids} = leg, s) when map_size(mids) > 0 do
    slots = for {other, slot} <- leg.assign, mid = mids[slot], into: %{}, do: {mid, other}
    push(leg, s, "group:slots", %{slots: slots})
  end

  defp push_slots(_, _), do: :ok

  defp push(leg, s, event, data) do
    payload =
      if event == "media",
        do: %{call_id: s.call.id, to_device: leg.device, data: data},
        else: Map.merge(%{call_id: s.call.id, to_device: leg.device}, data)

    CalleeWeb.Endpoint.broadcast(Callee.Calls.user_topic(leg.party), event, payload)
  end

  @impl true
  def terminate(_, s) do
    for {_k, l} <- s.legs do
      if l.writer, do: Writer.close(l.writer)
      if l.pc, do: PeerConnection.close(l.pc)
    end

    :ok
  catch
    _, _ -> :ok
  end
end
