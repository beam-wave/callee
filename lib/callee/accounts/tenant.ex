defmodule Callee.Accounts.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :name, :string
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :expires_at, :utc_datetime
    field :disabled, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def create_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :username, :password, :expires_at])
    |> validate_required([:name, :username, :password, :expires_at])
    |> validate_format(:username, ~r/^[a-zA-Z0-9_.-]{3,40}$/,
      message: "3-40 chars: letters, digits, _ . -"
    )
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> Callee.Accounts.hash_password()
  end

  def update_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :expires_at, :disabled, :password])
    |> validate_required([:name, :expires_at])
    |> validate_length(:password, min: 8, max: 72)
    |> Callee.Accounts.hash_password()
  end

  @doc "A tenant is active when not disabled and not past its expiry."
  def active?(%__MODULE__{disabled: true}), do: false

  def active?(%__MODULE__{expires_at: exp}),
    do: DateTime.compare(exp, DateTime.utc_now()) == :gt
end
