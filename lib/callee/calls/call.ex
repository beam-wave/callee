defmodule Callee.Calls.Call do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @statuses ~w(ringing active completed missed rejected cancelled busy failed)

  schema "calls" do
    belongs_to :tenant, Callee.Accounts.Tenant
    belongs_to :client, Callee.Accounts.Client
    field :caller_type, :string
    field :kind, :string, default: "direct"
    belongs_to :group, Callee.Groups.Group
    has_many :participants, Callee.Calls.Participant
    field :status, :string
    field :end_reason, :string
    field :answered_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :duration_seconds, :integer
    has_one :recording, Callee.Calls.Recording
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(call, attrs) do
    call
    |> cast(attrs, [:status, :end_reason, :answered_at, :ended_at, :duration_seconds])
    |> validate_inclusion(:status, @statuses)
  end
end
