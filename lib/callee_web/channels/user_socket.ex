defmodule CalleeWeb.UserSocket do
  use Phoenix.Socket
  alias CalleeWeb.Auth

  channel "user:*", CalleeWeb.CallChannel

  # params: token (Phoenix.Token from page), device_id (random per browser tab)
  @impl true
  def connect(%{"token" => token, "device_id" => device}, socket, _connect_info)
      when is_binary(device) and byte_size(device) in 8..64 do
    with {:ok, {role, id}} when role in ["tenant", "client"] <- Auth.verify_socket_token(token),
         user when not is_nil(user) <- Auth.load_user(role, id) do
      {:ok,
       socket
       |> assign(:party, {String.to_existing_atom(role), id})
       |> assign(:device_id, device)
       |> assign(:user, user)}
    else
      _ -> :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(socket) do
    {t, id} = socket.assigns.party
    "socket:#{t}:#{id}"
  end
end
