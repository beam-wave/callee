defmodule CalleeWeb.DeviceApiController do
  @moduledoc """
  JSON API for the Android app's native code. Authenticated with the same
  long-lived socket token the app's background service already holds
  (`Authorization: Bearer <token>`).
  """
  use CalleeWeb, :controller
  alias Callee.{Calls, FCM}
  alias CalleeWeb.Auth

  plug :authenticate

  defp authenticate(conn, _) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, {role, id}} when role in ["tenant", "client"] <- Auth.verify_socket_token(token),
         user when not is_nil(user) <- Auth.load_user(role, id) do
      assign(conn, :party, {String.to_existing_atom(role), id})
    else
      _ -> conn |> put_status(401) |> json(%{error: "unauthorized"}) |> halt()
    end
  end

  @doc "Register / refresh this phone's FCM token."
  def register(conn, %{"token" => token} = p) do
    :ok = FCM.register(conn.assigns.party, token, p["platform"] || "android")
    json(conn, %{ok: true, fcm: FCM.enabled?()})
  end

  def unregister(conn, %{"token" => token}) do
    FCM.unregister(token)
    json(conn, %{ok: true})
  end

  @doc "Decline from the ringing notification without opening the app."
  def reject(conn, %{"id" => id}) do
    case Calls.reject(id, conn.assigns.party) do
      :ok -> json(conn, %{ok: true})
      {:error, r} -> conn |> put_status(409) |> json(%{error: to_string(r)})
    end
  end
end
