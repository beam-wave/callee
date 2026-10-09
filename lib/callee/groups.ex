defmodule Callee.Groups do
  @moduledoc "Saved call groups: a tenant's named set of contacts to call together."
  import Ecto.Query
  import Ecto.Changeset
  alias Callee.{Repo, Pagination}
  alias Callee.Accounts.Contact

  defmodule Group do
    use Ecto.Schema

    schema "groups" do
      field :name, :string
      belongs_to :tenant, Callee.Accounts.Tenant

      many_to_many :members, Callee.Accounts.Client,
        join_through: "group_members",
        on_replace: :delete

      timestamps(type: :utc_datetime)
    end
  end

  def max_members, do: Application.get_env(:callee, :group_max, 50) - 1

  def paginate(tenant_id, opts) do
    q =
      from g in Group,
        where: g.tenant_id == ^tenant_id,
        order_by: [asc: fragment("lower(?)", g.name)],
        preload: [:members]

    q =
      case String.trim(opts["q"] || "") do
        "" -> q
        term -> where(q, [g], ilike(g.name, ^Pagination.like(term)))
      end

    Pagination.paginate(q, opts["page"], 20)
  end

  def get(tenant_id, id),
    do: Repo.get_by(Group, id: id, tenant_id: tenant_id) |> Repo.preload(:members)

  @doc "Members as [{client_id, contact_name}] — only those still in the tenant's address book."
  def members_with_names(%Group{} = g) do
    ids = Enum.map(g.members, & &1.id)

    Repo.all(
      from c in Contact,
        where: c.tenant_id == ^g.tenant_id and c.client_id in ^ids,
        order_by: c.name,
        select: {c.client_id, c.name}
    )
  end

  def save(tenant_id, attrs, group \\ nil) do
    ids = attrs["client_ids"] |> List.wrap() |> Enum.map(&to_int/1) |> Enum.uniq()

    clients =
      Repo.all(
        from c in Contact,
          where: c.tenant_id == ^tenant_id and c.client_id in ^ids,
          join: cl in assoc(c, :client),
          select: cl
      )

    (group || %Group{tenant_id: tenant_id})
    |> Repo.preload(:members)
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> put_assoc(:members, clients)
    |> validate_change(:members, fn _, _ ->
      cond do
        length(clients) < 2 -> [members: "pick at least 2 people"]
        length(clients) > max_members() -> [members: "can have at most #{max_members()} people"]
        true -> []
      end
    end)
    |> unique_constraint([:tenant_id, :name], message: "you already have a group with this name")
    |> Repo.insert_or_update()
  end

  def delete(tenant_id, id),
    do: Repo.delete_all(from g in Group, where: g.id == ^id and g.tenant_id == ^tenant_id)

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s), do: String.to_integer(to_string(s))
end
