defmodule Callee.Recording do
  @moduledoc """
  Recording adapter, picked by `RECORDING_MODE`:

    * `"server"` (default): audio is routed through `Callee.Media.Session`,
      which bridges the two browsers and records both sides to disk as the call
      runs. Survives tab crashes, phone sleep and very long calls.
    * `"client"`: classic peer-to-peer call; the tenant's browser mixes and
      records, uploading 1-minute chunks *during* the call
      (`Callee.Recording.ClientUploads`). A crash loses at most the last chunk.
    * `"off"`: peer-to-peer, no recording.

  The call state machine only talks to this module.
  """
  require Logger
  alias Callee.Calls
  alias Callee.Calls.RecordingProcessor
  alias Callee.Media.Session

  @callback_note "keep CallServer adapter-agnostic"
  def __note__, do: @callback_note

  def mode, do: Application.get_env(:callee, :recording_mode, "server")

  @doc "How browsers should send media for calls: \"server\" or \"p2p\"."
  def media_mode, do: if(mode() == "server", do: "server", else: "p2p")

  @doc "Whether the tenant browser must record (client mode)."
  def browser_records?, do: mode() == "client"

  @doc "Called when a call is answered."
  def on_active(call, legs) do
    case mode() do
      "server" ->
        {:ok, _} =
          Calls.create_recording(call, %{
            s3_key: "pending",
            content_type: "audio/ogg",
            status: "recording",
            mode: "server"
          })

        Session.start(call: call, legs: legs, record: true)

      "client" ->
        Calls.create_recording(call, %{
          s3_key: "pending",
          content_type: "application/octet-stream",
          status: "recording",
          mode: "client"
        })

        :ok

      _ ->
        :ok
    end
  rescue
    e -> Logger.error("recording on_active failed: #{Exception.message(e)}")
  end

  @doc "Called when an answered call ends (any reason)."
  def on_end(call) do
    case mode() do
      "server" ->
        Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
          case Session.stop_and_collect(call.id) do
            {:ok, %{files: files, dir: dir}} ->
              RecordingProcessor.process_server(call, files, dir)

            other ->
              Logger.error("server recording collect failed: #{inspect(other)}")
          end
        end)

      "client" ->
        # Tab normally sends a final chunk; if it died, finalize what we have.
        Callee.Recording.ClientUploads.finalize_later(call.id)

      _ ->
        :ok
    end
  end
end
