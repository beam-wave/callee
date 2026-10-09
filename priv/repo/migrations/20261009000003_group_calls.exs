defmodule Callee.Repo.Migrations.GroupCalls do
  use Ecto.Migration

  def change do
    alter table(:calls) do
      # "direct" (1:1) or "group" (tenant + several clients)
      add :kind, :string, null: false, default: "direct"
    end

    # Group calls have no single client.
    execute "ALTER TABLE calls ALTER COLUMN client_id DROP NOT NULL",
            "ALTER TABLE calls ALTER COLUMN client_id SET NOT NULL"

    create table(:call_participants) do
      add :call_id, references(:calls, type: :binary_id, on_delete: :delete_all), null: false
      add :client_id, references(:clients, on_delete: :delete_all), null: false
      # ringing | joined | declined | missed | left | busy
      add :status, :string, null: false
      add :joined_at, :utc_datetime_usec
      add :left_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:call_participants, [:call_id, :client_id])
    create index(:call_participants, [:client_id, :inserted_at])
  end
end
