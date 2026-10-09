defmodule Callee.MediaSessionTest do
  @moduledoc "Two ex_webrtc peers stand in for browsers and talk through the server session."
  use ExUnit.Case, async: false
  alias ExWebRTC.{PeerConnection, MediaStreamTrack, SessionDescription, ICECandidate}
  alias Callee.Media.Session

  @moduletag timeout: 30_000

  setup do
    dir = Path.join(System.tmp_dir!(), "callee-test-rec-#{System.unique_integer([:positive])}")
    Application.put_env(:callee, :recording_dir, dir)
    Application.put_env(:callee, :media_port_range, "")
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  # Fake browser: owns a PC, relays its signalling through Session as `party`.
  defp browser(call_id, party, device, test_pid) do
    spawn_link(fn ->
      CalleeWeb.Endpoint.subscribe(Callee.Calls.user_topic(party))
      {:ok, pc} = PeerConnection.start_link(audio_codecs: [:opus], video_codecs: [])
      track = MediaStreamTrack.new(:audio, [MediaStreamTrack.generate_stream_id()])
      {:ok, _} = PeerConnection.add_track(pc, track)
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)
      :ok = Session.signal(call_id, party, device, %{"type" => "offer", "sdp" => offer.sdp})

      loop(%{
        pc: pc,
        track: track,
        call_id: call_id,
        party: party,
        device: device,
        test: test_pid,
        got: 0
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

      {:ex_webrtc, _, {:ice_candidate, c}} ->
        Session.signal(st.call_id, st.party, st.device, %{
          "type" => "candidate",
          "candidate" => ICECandidate.to_json(c)
        })

        loop(st)

      {:ex_webrtc, _, {:connection_state_change, :connected}} ->
        send(st.test, {:connected, st.device})
        loop(st)

      {:ex_webrtc, _, {:rtp, _, _, _pkt}} ->
        if st.got == 0, do: send(st.test, {:received_audio, st.device})
        loop(%{st | got: st.got + 1})

      {:send_audio, n, gap_after} ->
        # 20 ms Opus frames; skip `gap_after`..+25 to simulate DTX silence.
        for i <- 0..(n - 1), !(gap_after && i in gap_after..(gap_after + 25)) do
          pkt = ExRTP.Packet.new(<<0xFC, 0xFF, 0xFE>>, sequence_number: i, timestamp: i * 960)
          PeerConnection.send_rtp(st.pc, st.track.id, pkt)
          Process.sleep(2)
        end

        send(st.test, {:sent, st.device})
        loop(st)

      _ ->
        loop(st)
    end
  end

  test "bridges audio between both legs and records both sides with gaps filled" do
    call = %{id: Ecto.UUID.generate()}
    a = {:tenant, 900_001}
    b = {:client, 900_002}

    {:ok, _} =
      Session.start(
        call: call,
        legs: [{:caller, a, "dev-a"}, {:callee, b, "dev-b"}],
        record: true
      )

    pa = browser(call.id, a, "dev-a", self())
    pb = browser(call.id, b, "dev-b", self())
    assert_receive {:connected, "dev-a"}, 10_000
    assert_receive {:connected, "dev-b"}, 10_000

    send(pa, {:send_audio, 100, 40})
    send(pb, {:send_audio, 100, nil})
    assert_receive {:received_audio, "dev-b"}, 5_000
    assert_receive {:received_audio, "dev-a"}, 5_000
    assert_receive {:sent, "dev-a"}, 5_000
    assert_receive {:sent, "dev-b"}, 5_000
    Process.sleep(300)

    assert {:ok, %{files: files}} = Session.stop_and_collect(call.id)
    assert length(files) == 2

    # Caller had a 26-frame gap that must be filled: both tracks ~ same packet count.
    counts =
      for f <- files do
        {:ok, r} = ExWebRTC.Media.Ogg.Reader.open(f)
        count_packets(r, 0)
      end

    assert Enum.all?(counts, &(&1 >= 100))
  end

  defp count_packets(r, n) do
    case ExWebRTC.Media.Ogg.Reader.next_packet(r) do
      {:ok, {_pkt, _dur}, r} -> count_packets(r, n + 1)
      {:ok, _pkt, r} -> count_packets(r, n + 1)
      _ -> n
    end
  end
end
