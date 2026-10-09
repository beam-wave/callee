defmodule CalleeWeb.PushController do
  use CalleeWeb, :controller

  def subscribe(conn, %{"subscription" => sub}) do
    party = {String.to_existing_atom(conn.assigns.current_role), conn.assigns.current_user.id}

    case Callee.Push.subscribe(party, sub) do
      :ok -> json(conn, %{ok: true})
      _ -> conn |> put_status(422) |> json(%{error: "invalid"})
    end
  end

  def unsubscribe(conn, %{"endpoint" => ep}) do
    Callee.Push.unsubscribe(ep)
    json(conn, %{ok: true})
  end
end
