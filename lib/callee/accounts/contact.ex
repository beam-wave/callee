defmodule Callee.Accounts.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contacts" do
    field :name, :string
    belongs_to :tenant, Callee.Accounts.Tenant
    belongs_to :client, Callee.Accounts.Client
    timestamps(type: :utc_datetime)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> unique_constraint([:tenant_id, :client_id],
      message: "this mobile is already in your address book"
    )
  end
end
