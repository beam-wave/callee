defmodule Callee.Calls.RecordingProcessor do
  @moduledoc """
  Takes the raw browser recording (WebM/Opus from Chrome/Firefox, MP4/AAC from
  Safari), converts to .m4a (AAC, plays everywhere) with ffmpeg when available,
  uploads to S3 and marks the recording ready.
  """
  require Logger
  alias Callee.{Calls, Storage}

  def process(recording, src_path, src_type) do
    {path, type, ext} = convert(src_path, src_type)
    key = "recordings/tenant-#{recording.tenant_id}/#{recording.call_id}.#{ext}"

    case Storage.upload_file(path, key, type) do
      {:ok, _} ->
        size = File.stat!(path).size

        Calls.update_recording(recording, %{
          s3_key: key,
          content_type: type,
          size_bytes: size,
          duration_seconds: probe_duration(path) || recording.duration_seconds,
          status: "ready"
        })

      err ->
        Logger.error("recording upload failed: #{inspect(err)}")
        Calls.update_recording(recording, %{status: "failed"})
    end
  after
    File.rm(src_path)
    File.rm(src_path <> ".m4a")
    File.rmdir(Path.dirname(src_path))
  end

  @doc "Server mode: mix caller/callee Ogg tracks into one .m4a and upload."
  def process_server(call, files, dir) do
    rec = Callee.Repo.get_by!(Callee.Calls.Recording, call_id: call.id)
    out = Path.join(dir, "mixed.m4a")

    args =
      case files do
        [] ->
          nil

        [one] ->
          ~w(-y -loglevel error -i #{one} -vn -ac 1 -c:a aac -b:a 48k -movflags +faststart #{out})

        many ->
          inputs = Enum.flat_map(many, &["-i", &1])

          ["-y", "-loglevel", "error"] ++
            inputs ++
            [
              "-filter_complex",
              "amix=inputs=#{length(many)}:duration=longest:normalize=0",
              "-ac",
              "1",
              "-c:a",
              "aac",
              "-b:a",
              "48k",
              "-movflags",
              "+faststart",
              out
            ]
      end

    with false <- is_nil(args),
         ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         {_, 0} <- System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      upload(rec, out, "audio/mp4", "m4a")
    else
      true ->
        Calls.update_recording(rec, %{status: "failed"})

      _ ->
        # No ffmpeg: keep the caller-side track at least.
        upload(rec, hd(files), "audio/ogg", "ogg")
    end
  after
    File.rm_rf(dir)
  end

  defp upload(rec, path, type, ext) do
    key = "recordings/tenant-#{rec.tenant_id}/#{rec.call_id}.#{ext}"

    case Storage.upload_file(path, key, type) do
      {:ok, _} ->
        Calls.update_recording(rec, %{
          s3_key: key,
          content_type: type,
          size_bytes: File.stat!(path).size,
          duration_seconds: probe_duration(path) || rec.duration_seconds,
          status: "ready"
        })

      err ->
        Logger.error("recording upload failed: #{inspect(err)}")
        Calls.update_recording(rec, %{status: "failed"})
    end
  end

  defp convert(src, src_type) do
    out = src <> ".m4a"

    with ffmpeg when is_binary(ffmpeg) <- System.find_executable("ffmpeg"),
         {_, 0} <-
           System.cmd(
             ffmpeg,
             ~w(-y -loglevel error -i #{src} -vn -ac 1 -c:a aac -b:a 48k -movflags +faststart #{out}),
             stderr_to_stdout: true
           ) do
      {out, "audio/mp4", "m4a"}
    else
      _ ->
        Logger.warning("ffmpeg unavailable/failed, storing original #{src_type}")
        ext = if String.contains?(src_type, "mp4"), do: "m4a", else: "webm"
        {src, src_type, ext}
    end
  end

  defp probe_duration(path) do
    with ffprobe when is_binary(ffprobe) <- System.find_executable("ffprobe"),
         {out, 0} <-
           System.cmd(ffprobe, ~w(-v error -show_entries format=duration -of csv=p=0 #{path})),
         {f, _} <- Float.parse(String.trim(out)) do
      round(f)
    else
      _ -> nil
    end
  end
end
