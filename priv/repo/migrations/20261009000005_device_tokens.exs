defmodule Callee.Repo.Migrations.DeviceTokens do
  use Ecto.Migration

  def change do
    # Native app push tokens (Firebase Cloud Messaging)
    create table(:device_tokens) do
      add :owner_type, :string, null: false
      add :owner_id, :bigint, null: false
      add :token, :text, null: false
      add :platform, :string, null: false, default: "android"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:device_tokens, [:token])
    create index(:device_tokens, [:owner_type, :owner_id])
  end
end
