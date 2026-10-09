defmodule CalleeWeb.RecordingController do
  use CalleeWeb, :controller
  alias Callee.{Calls, Storage}

  @doc """
  RECORDING_MODE=client: the tenant browser uploads its recording in sequential
  chunks during the call (`seq` = 0, 1, 2 ...; `final=1` on the last).
  Responds with the next sequence number the server expects, so a client that
  lost track can resume. 409 means "send part `expected` next".
  """
  def create(conn, %{"call_id" => call_id, "file" => %Plug.Upload{} = up} = params) do
    tenant = conn.assigns.current_user

    with {:ok, _} <- Ecto.UUID.cast(call_id),
         %{tenant_id: tid} = call when tid == tenant.id <- Calls.get_call(call_id) do
      seq = parse_int(params["seq"]) || 0
      final? = params["final"] in ["1", "true"]
      type = (up.content_type || "audio/webm") |> String.split(";") |> hd()

      case Callee.Recording.ClientUploads.append(
             call,
             seq,
             up,
             type,
             final?,
             parse_int(params["duration"])
           ) do
        {:ok, next} ->
          json(conn, %{ok: true, next: next})

        {:error, {:expected, n}} ->
          conn |> put_status(409) |> json(%{error: "out_of_order", expected: n})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{error: to_string(reason)})
      end
    else
      _ -> conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  def show(conn, %{"id" => id}) do
    tenant = conn.assigns.current_user

    case Calls.get_recording_for_tenant(tenant.id, id) do
      nil ->
        conn |> put_status(404) |> text("Not found")

      rec ->
        if Storage.direct_playback?() do
          {:ok, url} = Storage.presigned_get(rec.s3_key, Path.basename(rec.s3_key))
          redirect(conn, external: url)
        else
          stream_recording(conn, rec)
        end
    end
  end

  # S3 is internal-only: proxy through the app, honouring Range so audio
  # players (Safari in particular) can seek. Bounded chunks keep memory flat.
  @chunk 1_048_576
  defp stream_recording(conn, rec) do
    {:ok, %{headers: h}} = Storage.head(rec.s3_key)
    size = h |> header("content-length") |> String.to_integer()

    {first, last, status} =
      case conn |> get_req_header("range") |> List.first() |> parse_range(size) do
        {a, b} -> {a, min(b, a + @chunk - 1), 206}
        nil when size <= @chunk -> {0, size - 1, 200}
        nil -> {0, @chunk - 1, 206}
      end

    {:ok, %{body: body}} = Storage.get_range(rec.s3_key, first, last)

    conn
    |> put_resp_content_type(rec.content_type, nil)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("cache-control", "private, max-age=600")
    |> put_resp_header("content-disposition", ~s(inline; filename="#{Path.basename(rec.s3_key)}"))
    |> then(fn c ->
      if status == 206,
        do: put_resp_header(c, "content-range", "bytes #{first}-#{last}/#{size}"),
        else: c
    end)
    |> send_resp(status, body)
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> String.downcase(k) == name && v end)
  end

  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] -> {max(size - String.to_integer(suffix), 0), size - 1}
      [a, ""] -> {String.to_integer(a), size - 1}
      [a, b] -> {String.to_integer(a), min(String.to_integer(b), size - 1)}
    end
  rescue
    _ -> nil
  end

  defp parse_range(_, _), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(s),
    do:
      (case Integer.parse(to_string(s)) do
         {i, _} -> i
         _ -> nil
       end)
end
