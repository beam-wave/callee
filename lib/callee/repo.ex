defmodule Callee.Repo do
  use Ecto.Repo,
    otp_app: :callee,
    adapter: Ecto.Adapters.Postgres
end
