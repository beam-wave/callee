defmodule Callee.Calls.Recording do
  use Ecto.Schema
  import Ecto.Changeset

  schema "recordings" do
    belongs_to :call, Callee.Calls.Call, type: :binary_id
    belongs_to :tenant, Callee.Accounts.Tenant
    field :s3_key, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :duration_seconds, :integer
    field :status, :string, default: "processing"
    field :mode, :string, default: "client"
    field :parts_received, :integer, default: 0
    field :bytes_received, :integer, default: 0
    timestamps(type: :utc_datetime)
  end

  def changeset(r, attrs),
    do:
      cast(r, attrs, [
        :s3_key,
        :content_type,
        :size_bytes,
        :duration_seconds,
        :status,
        :mode,
        :parts_received,
        :bytes_received
      ])
end
