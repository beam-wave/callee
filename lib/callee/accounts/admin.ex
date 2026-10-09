defmodule Callee.Accounts.Admin do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admins" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    timestamps(type: :utc_datetime)
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_length(:password, min: 8)
    |> unique_constraint(:username)
    |> Callee.Accounts.hash_password()
  end
end
