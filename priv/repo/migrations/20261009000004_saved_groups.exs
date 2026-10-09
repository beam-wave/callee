defmodule Callee.Repo.Migrations.SavedGroups do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, [:tenant_id, :name])

    create table(:group_members, primary_key: false) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false, primary_key: true
      add :client_id, references(:clients, on_delete: :delete_all), null: false, primary_key: true
    end

    alter table(:calls) do
      add :group_id, references(:groups, on_delete: :nilify_all)
    end
  end
end
