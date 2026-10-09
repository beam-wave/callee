defmodule Callee.MediaRoomTest do
  @moduledoc "Three ex_webrtc peers act as browsers in one group room."
  use ExUnit.Case, async: false
  alias ExWebRTC.{PeerConnection, MediaStreamTrack, SessionDescription, ICECandidate}
  alias Callee.Media.Room

  @moduletag timeout: 30_000

  setup do
    dir = Path.join(System.tmp_dir!(), "callee-room-#{System.unique_integer([:positive])}")
    Application.put_env(:callee, :recording_dir, dir)
    Application.put_env(:callee, :media_port_range, "")
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  defp browser(call_id, party, device, slots, test) do
    spawn_link(fn ->
      CalleeWeb.Endpoint.subscribe(Callee.Calls.user_topic(party))
      {:ok, pc} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
      mic = MediaStreamTrack.new(:audio, [MediaStreamTrack.generate_stream_id()])
      {:ok, _} = PeerConnection.add_track(pc, mic)
      for _ <- 2..slots//1, do: PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)
      :ok = Room.signal(call_id, party, device, %{"type" => "offer", "sdp" => offer.sdp})

      loop(%{
        pc: pc,
        mic: mic,
        call_id: call_id,
        party: party,
        device: device,
        test: test,
        from: MapSet.new(),
        tracks: %{},
        slots: %{}
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
        loop(st)

      {:ex_webrtc, _, {:track, track}} ->
        loop(%{st | tracks: Map.put(st.tracks, track.id, track)})

      {:ex_webrtc, pc, {:rtp, track_id, _, pkt}} ->
        # which mid did it arrive on? map to participant via slot map
        mid =
          Enum.find_value(PeerConnection.get_transceivers(pc), fn tr ->
            tr.receiver.track.id == track_id && tr.mid
          end)

        who = st.slots[mid]

        st =
          if who && !MapSet.member?(st.from, who),
            do:
              (
                send(st.test, {:heard, st.device, who, pkt.payload})
                %{st | from: MapSet.put(st.from, who)}
              ),
            else: st

        loop(st)

      {:send_audio, tag, n} ->
        for i <- 0..(n - 1) do
          PeerConnection.send_rtp(
            st.pc,
            st.mic.id,
            ExRTP.Packet.new(tag, sequence_number: i, timestamp: i * 960)
          )

          Process.sleep(3)
        end

        loop(st)

      _ ->
        loop(st)
    end
  end

  test "each participant hears every other participant on the right slot" do
    call = %{id: Ecto.UUID.generate()}
    slots = 2
    {:ok, _} = Room.start(call: call, slots: slots, record: true)

    parties = [
      {"host", {:tenant, 800_001}, "dh"},
      {"c1", {:client, 800_002}, "d1"},
      {"c2", {:client, 800_003}, "d2"}
    ]

    for {k, p, d} <- parties, do: :ok = Room.add_leg(call.id, k, p, d)

    pids = for {k, p, d} <- parties, into: %{}, do: {k, browser(call.id, p, d, slots, self())}
    for {_, _, d} <- parties, do: assert_receive({:connected, ^d}, 10_000)

    # distinct "audio" per speaker so we can tell who is heard where
    send(pids["host"], {:send_audio, <<0xFC, 1>>, 60})
    send(pids["c1"], {:send_audio, <<0xFC, 2>>, 60})
    send(pids["c2"], {:send_audio, <<0xFC, 3>>, 60})

    expected = %{"dh" => ["c1", "c2"], "d1" => ["c2", "host"], "d2" => ["c1", "host"]}
    tags = %{"host" => <<0xFC, 1>>, "c1" => <<0xFC, 2>>, "c2" => <<0xFC, 3>>}

    for {dev, whos} <- expected, who <- whos do
      tag = tags[who]
      assert_receive {:heard, ^dev, ^who, ^tag}, 5_000
    end

    # c2 leaves: remaining legs get updated slot maps without it
    flush = fn f -> receive do: ({:slots, _, _} -> f.(f)), after: (100 -> :ok) end
    flush.(flush)
    :ok = Room.remove_leg(call.id, "c2")
    assert_receive {:slots, "dh", s}, 2_000
    refute "c2" in Map.values(s)

    assert {:ok, %{files: files}} = Room.finish(call.id)
    assert length(files) == 3
  end
end
