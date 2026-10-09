defmodule Callee.Accounts.Admin do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admins" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    timestamps(type: :utc_datetime)
  end

  def changeset(admin, attrs, opts \\ []) do
    admin
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    # The bootstrap admin from ADMIN_PASSWORD may be short on dev servers.
    |> validate_length(:password, min: Keyword.get(opts, :min_password, 8))
    |> unique_constraint(:username)
    |> Callee.Accounts.hash_password()
  end
end
