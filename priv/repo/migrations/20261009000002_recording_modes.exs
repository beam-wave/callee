defmodule Callee.Repo.Migrations.RecordingModes do
  use Ecto.Migration

  def change do
    alter table(:recordings) do
      # "client" (tenant browser uploads chunks) or "server" (media server records)
      add :mode, :string, null: false, default: "client"
      add :parts_received, :integer, null: false, default: 0
      add :bytes_received, :bigint, null: false, default: 0
    end
  end
end
