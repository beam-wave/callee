defmodule Callee.Recording.ClientUploads do
  @moduledoc """
  Chunked uploads for RECORDING_MODE=client. The tenant browser's MediaRecorder
  emits sequential chunks of ONE file; appending them in order rebuilds the file.
  Parts are acknowledged by sequence number so retries are idempotent.
  """
  import Ecto.Query
  require Logger
  alias Callee.Repo
  alias Callee.Calls.{Recording, RecordingProcessor}

  @grace :timer.seconds(90)

  def path(call_id),
    do: Path.join([Application.get_env(:callee, :recording_dir), call_id, "client.part"])

  @doc """
  Append part `seq`. Returns {:ok, next_expected_seq} or {:error, reason}.
  Already-received parts are acknowledged without writing again.
  """
  def append(call, seq, %Plug.Upload{} = up, content_type, final?, duration) do
    Repo.transaction(fn ->
      rec =
        Repo.one(
          from r in Recording,
            where: r.call_id == ^call.id and r.mode == "client",
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(rec) ->
          Repo.rollback(:no_recording)

        rec.status not in ["recording", "uploading"] ->
          {rec, rec.parts_received, false}

        seq < rec.parts_received ->
          {rec, rec.parts_received, final?}

        seq > rec.parts_received ->
          Repo.rollback({:expected, rec.parts_received})

        true ->
          p = path(call.id)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, File.read!(up.path), [:append])

          {:ok, rec} =
            rec
            |> Recording.changeset(%{
              parts_received: seq + 1,
              bytes_received: rec.bytes_received + up_size(up),
              content_type: if(seq == 0, do: content_type, else: rec.content_type),
              duration_seconds: duration || rec.duration_seconds,
              status: "uploading"
            })
            |> Repo.update()

          {rec, seq + 1, final?}
      end
    end)
    |> case do
      {:ok, {rec, next, true}} ->
        finalize(rec)
        {:ok, next}

      {:ok, {_rec, next, _}} ->
        {:ok, next}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp up_size(up), do: File.stat!(up.path).size

  def finalize_later(call_id) do
    Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
      Process.sleep(Application.get_env(:callee, :client_upload_grace_ms, @grace))

      case Repo.get_by(Recording, call_id: call_id, mode: "client") do
        %{status: s} = rec when s in ["recording", "uploading"] -> finalize(rec)
        _ -> :ok
      end
    end)
  end

  @doc "Claim the recording for processing exactly once."
  def finalize(rec) do
    {n, _} =
      from(r in Recording, where: r.id == ^rec.id and r.status in ["recording", "uploading"])
      |> Repo.update_all(set: [status: "processing"])

    cond do
      n == 0 ->
        :already

      rec.parts_received == 0 and not File.exists?(path(rec.call_id)) ->
        Callee.Calls.update_recording(%{rec | status: "processing"}, %{status: "failed"})

      true ->
        Task.Supervisor.start_child(Callee.TaskSupervisor, fn ->
          RecordingProcessor.process(
            Repo.get!(Recording, rec.id),
            path(rec.call_id),
            rec.content_type
          )
        end)
    end
  end
end
