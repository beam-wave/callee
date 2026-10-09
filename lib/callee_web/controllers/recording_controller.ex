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
        {:ok, url} = Storage.presigned_get(rec.s3_key, Path.basename(rec.s3_key))
        redirect(conn, external: url)
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(s),
    do:
      (case Integer.parse(to_string(s)) do
         {i, _} -> i
         _ -> nil
       end)
end
