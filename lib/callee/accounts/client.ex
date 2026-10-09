defmodule Callee.Accounts.Client do
  use Ecto.Schema
  import Ecto.Changeset

  schema "clients" do
    field :mobile, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    timestamps(type: :utc_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:mobile, :password])
    |> update_change(:mobile, &Callee.Accounts.normalize_mobile/1)
    |> validate_required([:mobile, :password])
    |> validate_format(:mobile, ~r/^\+?[0-9]{7,15}$/, message: "must be 7-15 digits, optional +")
    |> validate_length(:password, min: 6, max: 72)
    |> unique_constraint(:mobile)
    |> Callee.Accounts.hash_password()
  end

  def password_changeset(client, attrs) do
    client
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 6, max: 72)
    |> Callee.Accounts.hash_password()
  end
end
