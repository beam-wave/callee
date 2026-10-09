defmodule Callee.Storage do
  @moduledoc "S3 (or S3-compatible, e.g. SeaweedFS/MinIO) storage for call recordings."
  require Logger

  def bucket, do: Application.fetch_env!(:callee, :s3_bucket)

  def ensure_bucket do
    case ExAws.S3.head_bucket(bucket()) |> ExAws.request() do
      {:ok, _} ->
        :ok

      _ ->
        region = Application.get_env(:ex_aws, :region, "us-east-1")
        res = ExAws.S3.put_bucket(bucket(), region) |> ExAws.request()
        Logger.info("create bucket #{bucket()}: #{inspect(elem(res, 0))}")
        :ok
    end
  rescue
    e -> Logger.error("bucket check failed: #{Exception.message(e)}")
  end

  def upload_file(path, key, content_type) do
    path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload(bucket(), key, content_type: content_type)
    |> ExAws.request()
  end

  @doc """
  Short-lived signed GET URL. Signed against S3_PUBLIC_ENDPOINT when set, so
  browsers can reach the S3 service even when the app talks to it over the docker network.
  Range requests work, which Safari needs for <audio>.
  """
  def presigned_get(key, filename) do
    config =
      case Application.get_env(:callee, :s3_public_endpoint) do
        nil ->
          ExAws.Config.new(:s3)

        url ->
          %URI{scheme: s, host: h, port: p} = URI.parse(url)
          ExAws.Config.new(:s3, scheme: "#{s}://", host: h, port: p)
      end

    ExAws.S3.presigned_url(config, :get, bucket(), key,
      expires_in: 600,
      query_params: [{"response-content-disposition", ~s(inline; filename="#{filename}")}]
    )
  end
end
