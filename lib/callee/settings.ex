defmodule Callee.Settings do
  @moduledoc "Tiny key/value store for app-generated secrets (e.g. VAPID keys)."
  import Ecto.Query
  alias Callee.Repo

  def get(key) do
    Repo.one(from s in "settings", where: s.key == ^key, select: s.value)
  end

  def put_new(key, value) do
    now = DateTime.utc_now(:second)

    Repo.insert_all("settings", [%{key: key, value: value, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )
  end
end
