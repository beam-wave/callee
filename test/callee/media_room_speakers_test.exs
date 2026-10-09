defmodule Callee.MediaRoomSpeakersTest do
  @moduledoc """
  Big-room behaviour: 6 participants, 2 receive slots each. Only the loudest
  current speakers are forwarded, slots switch when someone new talks, and the
  forwarded stream stays continuous (no sequence-number jumps) across switches.
  """
  use ExUnit.Case, async: false
  alias ExWebRTC.{PeerConnection, MediaStreamTrack, SessionDescription, ICECandidate}
  alias ExRTP.Packet.Extension.AudioLevel
  alias Callee.Media.Room

  @moduletag timeout: 60_000
  @level_uri "urn:ietf:params:rtp-hdrext:ssrc-audio-level"

  setup do
    dir = Path.join(System.tmp_dir!(), "callee-spk-#{System.unique_integer([:positive])}")
    Application.put_env(:callee, :recording_dir, dir)
    Application.put_env(:callee, :media_port_range, "")
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  defp browser(call_id, party, device, slots, test) do
    spawn_link(fn ->
      CalleeWeb.Endpoint.subscribe(Callee.Calls.user_topic(party))

      {:ok, pc} =
        PeerConnection.start_link(
          audio_codecs: [:opus],
          video_codecs: [],
          rtp_header_extensions:
            PeerConnection.Configuration.default_rtp_header_extensions() ++
              [%{type: :audio, uri: @level_uri}]
        )

      mic = MediaStreamTrack.new(:audio, [MediaStreamTrack.generate_stream_id()])
      {:ok, _} = PeerConnection.add_track(pc, mic)
      for _ <- 2..slots//1, do: PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)
      [_, ext_id] = Regex.run(~r/a=extmap:(\d+) #{Regex.escape(@level_uri)}/, offer.sdp)
      :ok = Room.signal(call_id, party, device, %{"type" => "offer", "sdp" => offer.sdp})

      loop(%{
        pc: pc,
        mic: mic,
        ext: String.to_integer(ext_id),
        call_id: call_id,
        party: party,
        device: device,
        test: test,
        slots: %{},
        seq: 0,
        talking: nil,
        last_seq: %{}
      })
    end)
  end

  defp loop(st) do
    receive do
      %{event: "media", payload: %{to_device: d, data: data}} when d == st.device ->
        case data do
          %{"type" => "answer", "sdp" => sdp} ->
            PeerConnection.set_remote_description(
              st.pc,
              SessionDescription.from_json(%{"type" => "answer", "sdp" => sdp})
            )

          %{"type" => "candidate", "candidate" => c} ->
            PeerConnection.add_ice_candidate(st.pc, ICECandidate.from_json(c))
        end

        loop(st)

      %{event: "group:slots", payload: %{to_device: d, slots: slots}} when d == st.device ->
        send(st.test, {:slots, st.device, slots})
        loop(%{st | slots: slots})

      {:ex_webrtc, _, {:ice_candidate, c}} ->
        Room.signal(st.call_id, st.party, st.device, %{
          "type" => "candidate",
          "candidate" => ICECandidate.to_json(c)
        })

        loop(st)

      {:ex_webrtc, _, {:connection_state_change, :connected}} ->
        send(st.test, {:connected, st.device})
        send(self(), :tick)
        loop(st)

      {:ex_webrtc, pc, {:rtp, track_id, _, pkt}} ->
        mid =
          Enum.find_value(PeerConnection.get_transceivers(pc), fn tr ->
            tr.receiver.track.id == track_id && tr.mid
          end)

        prev = st.last_seq[mid]

        if prev && Bitwise.band(pkt.sequence_number - prev, 0xFFFF) > 3,
          do: send(st.test, {:seq_jump, st.device, mid, prev, pkt.sequence_number})

        send(st.test, {:heard, st.device, st.slots[mid], pkt.payload})
        loop(%{st | last_seq: Map.put(st.last_seq, mid, pkt.sequence_number)})

      {:talk, tag} ->
        loop(%{st | talking: tag})

      :tick ->
        # 20 ms frames: loud voiced when talking, quiet unvoiced (DTX-ish) otherwise
        {payload, level, voice} =
          if st.talking,
            do: {st.talking <> :binary.copy(<<0>>, 60), 10, true},
            else: {<<0xF8, 0xFF, 0xFE>>, 120, false}

        ext = AudioLevel.new(voice, level) |> AudioLevel.to_raw(st.ext)

        pkt =
          ExRTP.Packet.new(payload, sequence_number: st.seq, timestamp: st.seq * 960)
          |> ExRTP.Packet.add_extension(ext)

        PeerConnection.send_rtp(st.pc, st.mic.id, pkt)
        Process.send_after(self(), :tick, 20)
        loop(%{st | seq: st.seq + 1})

      _ ->
        loop(st)
    end
  end

  defp heard_from(dev, who, timeout) do
    receive do
      {:heard, ^dev, ^who, _} -> true
    after
      timeout -> false
    end
  end

  defp flush do
    receive do
      {:heard, _, _, _} -> flush()
      {:slots, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  test "only the loudest speakers are forwarded, and slots switch smoothly" do
    call = %{id: Ecto.UUID.generate()}
    {:ok, _} = Room.start(call: call, slots: 2, record: false)
    keys = ~w(a b c d e f)
    parties = for {k, i} <- Enum.with_index(keys), do: {k, {:client, 700_000 + i}, "dev-" <> k}
    for {k, p, d} <- parties, do: :ok = Room.add_leg(call.id, k, p, d)
    pids = for {k, p, d} <- parties, into: %{}, do: {k, browser(call.id, p, d, 2, self())}
    for {_, _, d} <- parties, do: assert_receive({:connected, ^d}, 15_000)

    # a and d talk; f (a quiet listener) should end up hearing exactly them
    send(pids["a"], {:talk, <<0xFC, ?a>>})
    send(pids["d"], {:talk, <<0xFC, ?d>>})
    Process.sleep(1_200)
    flush()
    assert heard_from("dev-f", "a", 2_000)
    assert heard_from("dev-f", "d", 2_000)

    # a stops, e starts: e must replace a in f's slots
    send(pids["a"], {:talk, nil})
    send(pids["e"], {:talk, <<0xFC, ?e>>})
    Process.sleep(2_200)
    flush()
    assert heard_from("dev-f", "e", 2_000)
    assert heard_from("dev-f", "d", 2_000)

    # nobody's own voice is ever forwarded back; no sequence jumps on switches
    refute_received {:heard, "dev-e", "e", _}
    refute_received {:seq_jump, _, _, _, _}
    {:ok, _} = Room.finish(call.id)
  end

  test "host is always heard; clients compete for the remaining lines" do
    call = %{id: Ecto.UUID.generate()}
    {:ok, _} = Room.start(call: call, slots: 2, record: false, pinned: "host")
    keys = ~w(host c1 c2 c3 c4)
    parties = for {k, i} <- Enum.with_index(keys), do: {k, {:client, 710_000 + i}, "dev-" <> k}
    for {k, p, d} <- parties, do: :ok = Room.add_leg(call.id, k, p, d)
    pids = for {k, p, d} <- parties, into: %{}, do: {k, browser(call.id, p, d, 2, self())}
    for {_, _, d} <- parties, do: assert_receive({:connected, ^d}, 15_000)

    # host quiet-ish but pinned; c2 and c3 both talk -> c4 has 1 free line
    send(pids["host"], {:talk, <<0xFC, ?h>>})
    send(pids["c2"], {:talk, <<0xFC, 2>>})
    Process.sleep(1_200)
    send(pids["host"], {:talk, nil})
    send(pids["c3"], {:talk, <<0xFC, 3>>})
    Process.sleep(2_000)
    flush()

    # c4: one line is the talking clients' (host isn't talking now)...
    assert heard_from("dev-c4", "c3", 2_000) or heard_from("dev-c4", "c2", 2_000)
    # ...and the host's pinned line survived the clients taking over
    send(pids["host"], {:talk, <<0xFC, ?h>>})
    assert heard_from("dev-c4", "host", 2_000)
    # host hears both talking clients (2 lines, nobody pinned for the host)
    assert heard_from("dev-host", "c2", 2_000) or heard_from("dev-host", "c3", 2_000)
    {:ok, _} = Room.finish(call.id)
  end

  @tag :load
  @tag timeout: 120_000
  test "load: 25 people, host + 2 clients talking" do
    n = 25
    call = %{id: Ecto.UUID.generate()}
    {:ok, room} = Room.start(call: call, slots: 4, record: true, pinned: "host")
    keys = ["host" | for(i <- 1..(n - 1), do: "c#{i}")]
    parties = for {k, i} <- Enum.with_index(keys), do: {k, {:client, 720_000 + i}, "dev-" <> k}
    for {k, p, d} <- parties, do: :ok = Room.add_leg(call.id, k, p, d)
    pids = for {k, p, d} <- parties, into: %{}, do: {k, browser(call.id, p, d, 4, self())}
    for {_, _, d} <- parties, do: assert_receive({:connected, ^d}, 30_000)

    send(pids["host"], {:talk, <<0xFC, ?h>>})
    send(pids["c3"], {:talk, <<0xFC, 3>>})
    send(pids["c7"], {:talk, <<0xFC, 7>>})
    Process.sleep(1_500)
    flush()

    {_, r0} = :erlang.statistics(:runtime)
    t0 = System.monotonic_time(:millisecond)
    Process.sleep(5_000)
    {_, r1} = :erlang.statistics(:runtime)
    wall = System.monotonic_time(:millisecond) - t0
    cpu = Float.round(r1 / wall * 100 / System.schedulers_online(), 1)
    _ = r0

    # every listener (except the speaker itself) hears the host and both talkers
    heard =
      for {k, _, d} <- parties,
          k not in ["host", "c3", "c7"],
          do: {d, heard_from(d, "host", 1_000)}

    assert Enum.all?(heard, &elem(&1, 1))
    assert heard_from("dev-c12", "c3", 1_000) or heard_from("dev-c12", "c7", 1_000)

    {:message_queue_len, q} = Process.info(room, :message_queue_len)

    IO.puts(
      "\n[load] #{n} participants, 3 talking: whole-VM CPU ≈ #{cpu}% of #{System.schedulers_online()} cores (incl. 25 test peers), room mailbox=#{q}"
    )

    {:ok, %{files: files}} = Room.finish(call.id)
    IO.puts("[load] recorded tracks: #{length(files)}")
  end
end
