defmodule Callee.Repo.Migrations.CreateCore do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:admins) do
      add :username, :citext, null: false
      add :password_hash, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:admins, [:username])

    create table(:tenants) do
      add :name, :string, null: false
      add :username, :citext, null: false
      add :password_hash, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :disabled, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:username])

    # A client is a global identity keyed by mobile number.
    create table(:clients) do
      add :mobile, :string, null: false
      add :password_hash, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:clients, [:mobile])

    # Address-book entry: links a tenant to a client. Same mobile may be in many tenants.
    create table(:contacts) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:contacts, [:tenant_id, :client_id])
    create index(:contacts, [:client_id])

    create table(:calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      add :caller_type, :string, null: false
      add :status, :string, null: false
      add :end_reason, :string
      add :answered_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :duration_seconds, :integer
      timestamps(type: :utc_datetime_usec)
    end

    create index(:calls, [:tenant_id, :inserted_at])
    create index(:calls, [:client_id, :inserted_at])

    create table(:recordings) do
      add :call_id, references(:calls, type: :binary_id, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :s3_key, :string, null: false
      add :content_type, :string, null: false
      add :size_bytes, :bigint
      add :duration_seconds, :integer
      add :status, :string, null: false, default: "processing"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:recordings, [:call_id])
    create index(:recordings, [:tenant_id])

    create table(:settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:push_subscriptions) do
      add :owner_type, :string, null: false
      add :owner_id, :bigint, null: false
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:owner_type, :owner_id])
  end
end
