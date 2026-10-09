defmodule Callee.Calls.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "call_participants" do
    belongs_to :call, Callee.Calls.Call, type: :binary_id
    belongs_to :client, Callee.Accounts.Client
    field :status, :string
    field :joined_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(p, attrs), do: cast(p, attrs, [:status, :joined_at, :left_at])
end
