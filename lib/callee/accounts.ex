defmodule Callee.Accounts do
  @moduledoc "Admins, tenants, clients and the tenant<->client address book."
  import Ecto.Query
  import Ecto.Changeset
  alias Ecto.Multi
  alias Callee.Repo
  alias Callee.Pagination
  alias Callee.Accounts.{Admin, Tenant, Client, Contact}

  ## Helpers

  def hash_password(%Ecto.Changeset{valid?: true, changes: %{password: pw}} = cs) do
    cs |> put_change(:password_hash, Bcrypt.hash_pwd_salt(pw)) |> delete_change(:password)
  end

  def hash_password(cs), do: cs

  def normalize_mobile(nil), do: nil
  def normalize_mobile(m), do: String.replace(m, ~r/[\s\-()]/, "")

  defp verify(nil, _pw), do: Bcrypt.no_user_verify() && :error

  defp verify(%{password_hash: h} = user, pw),
    do: if(Bcrypt.verify_pass(pw, h), do: {:ok, user}, else: :error)

  ## Admins

  def get_admin(id), do: Repo.get(Admin, id)

  def authenticate_admin(username, pw),
    do: verify(Repo.get_by(Admin, username: username), pw)

  def ensure_admin!(username, password) do
    case Repo.get_by(Admin, username: username) do
      nil ->
        %Admin{} |> Admin.changeset(%{username: username, password: password}) |> Repo.insert!()

      a ->
        a
    end
  end

  ## Tenants

  def list_tenants, do: Repo.all(from t in Tenant, order_by: [desc: t.inserted_at])

  @doc "Admin tenant list. opts: q (name/username), status (active|expired|disabled), page."
  def paginate_tenants(opts) do
    now = DateTime.utc_now()

    query =
      from t in Tenant, order_by: [desc: t.inserted_at, desc: t.id]

    query =
      case blank(opts["q"]) do
        nil -> query
        q -> where(query, [t], ilike(t.name, ^like(q)) or ilike(t.username, ^like(q)))
      end

    query =
      case opts["status"] do
        "active" -> where(query, [t], not t.disabled and t.expires_at > ^now)
        "expired" -> where(query, [t], not t.disabled and t.expires_at <= ^now)
        "disabled" -> where(query, [t], t.disabled)
        _ -> query
      end

    Pagination.paginate(query, opts["page"], 15)
  end

  def tenant_counts do
    now = DateTime.utc_now()

    Repo.one(
      from t in Tenant,
        select: %{
          all: count(t.id),
          active: filter(count(t.id), not t.disabled and t.expires_at > ^now),
          expired: filter(count(t.id), not t.disabled and t.expires_at <= ^now),
          disabled: filter(count(t.id), t.disabled)
        }
    )
  end

  defp blank(nil), do: nil
  defp blank(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp like(q), do: Pagination.like(q)
  def get_tenant(id), do: Repo.get(Tenant, id)
  def get_tenant!(id), do: Repo.get!(Tenant, id)

  def create_tenant(attrs), do: %Tenant{} |> Tenant.create_changeset(attrs) |> Repo.insert()
  def update_tenant(t, attrs), do: t |> Tenant.update_changeset(attrs) |> Repo.update()
  def change_tenant(t \\ %Tenant{}, attrs \\ %{}), do: Tenant.create_changeset(t, attrs)

  def authenticate_tenant(username, pw) do
    with {:ok, t} <- verify(Repo.get_by(Tenant, username: username), pw) do
      if Tenant.active?(t), do: {:ok, t}, else: {:error, :inactive}
    end
  end

  ## Clients

  def get_client(id), do: Repo.get(Client, id)

  def authenticate_client(mobile, pw),
    do: verify(Repo.get_by(Client, mobile: normalize_mobile(mobile)), pw)

  def change_client_password(%Client{} = c, attrs),
    do: c |> Client.password_changeset(attrs) |> Repo.update()

  ## Contacts (address book)

  @doc """
  Tenant adds a client by mobile. If the mobile already exists (created by another
  tenant), the existing client is linked and its password is NOT changed, so one
  tenant can't take over a client shared with other tenants.
  Returns {:ok, contact, :created | :linked}.
  """
  def add_contact(%Tenant{} = tenant, %{"mobile" => mobile} = attrs) do
    mobile = normalize_mobile(mobile)

    Multi.new()
    |> Multi.run(:client, fn repo, _ ->
      case repo.get_by(Client, mobile: mobile) do
        nil ->
          %Client{}
          |> Client.changeset(%{mobile: mobile, password: attrs["password"]})
          |> repo.insert()
          |> case do
            {:ok, c} -> {:ok, {c, :created}}
            err -> err
          end

        c ->
          {:ok, {c, :linked}}
      end
    end)
    |> Multi.run(:contact, fn repo, %{client: {c, _}} ->
      %Contact{tenant_id: tenant.id, client_id: c.id}
      |> Contact.changeset(%{name: attrs["name"]})
      |> repo.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{client: {c, how}, contact: contact}} -> {:ok, %{contact | client: c}, how}
      {:error, :client, cs, _} -> {:error, cs}
      {:error, :contact, cs, _} -> {:error, cs}
    end
  end

  @doc """
  A tenant may reset a client's password only when no other tenant shares that
  client, so one tenant can never lock a shared client out of other tenants.
  """
  def reset_client_password(%Tenant{id: tid}, contact_id, password) do
    with %Contact{} = c <-
           Repo.get_by(Contact, id: contact_id, tenant_id: tid) || {:error, :not_found},
         1 <-
           Repo.aggregate(from(x in Contact, where: x.client_id == ^c.client_id), :count) ||
             :shared do
      Repo.get!(Client, c.client_id)
      |> Client.password_changeset(%{password: password})
      |> Repo.update()
    else
      n when is_integer(n) -> {:error, :shared}
      other -> other
    end
  end

  def client_shared?(client_id),
    do: Repo.aggregate(from(x in Contact, where: x.client_id == ^client_id), :count) > 1

  def update_contact_name(%Tenant{id: tid}, contact_id, name) do
    case Repo.get_by(Contact, id: contact_id, tenant_id: tid) do
      nil -> {:error, :not_found}
      c -> c |> Contact.changeset(%{name: name}) |> Repo.update()
    end
  end

  def delete_contact(%Tenant{id: tid}, contact_id) do
    from(c in Contact, where: c.id == ^contact_id and c.tenant_id == ^tid) |> Repo.delete_all()
    :ok
  end

  def paginate_contacts_for_tenant(%Tenant{id: tid}, opts) do
    query =
      from c in Contact,
        where: c.tenant_id == ^tid,
        join: cl in assoc(c, :client),
        preload: [client: cl],
        order_by: [asc: fragment("lower(?)", c.name), asc: c.id]

    query =
      case blank(opts["q"]) do
        nil -> query
        q -> where(query, [c, cl], ilike(c.name, ^like(q)) or ilike(cl.mobile, ^like(q)))
      end

    Pagination.paginate(query, opts["page"], 20)
  end

  def paginate_tenants_for_client(%Client{id: cid}, opts) do
    query =
      from c in Contact,
        where: c.client_id == ^cid,
        join: t in assoc(c, :tenant),
        preload: [tenant: t],
        order_by: [asc: fragment("lower(?)", t.name), asc: t.id]

    query =
      case blank(opts["q"]) do
        nil -> query
        q -> where(query, [c, t], ilike(t.name, ^like(q)))
      end

    Pagination.paginate(query, opts["page"], 20)
  end

  def change_tenant_password(%Tenant{} = t, current, new) do
    if Bcrypt.verify_pass(current || "", t.password_hash),
      do: update_tenant(t, %{password: new}),
      else: {:error, :wrong_password}
  end

  def list_contacts_for_tenant(%Tenant{id: tid}) do
    Repo.all(
      from c in Contact,
        where: c.tenant_id == ^tid,
        join: cl in assoc(c, :client),
        preload: [client: cl],
        order_by: [asc: c.name]
    )
  end

  @doc "Tenants a client can see: every tenant that has them in its address book."
  def list_tenants_for_client(%Client{id: cid}) do
    Repo.all(
      from c in Contact,
        where: c.client_id == ^cid,
        join: t in assoc(c, :tenant),
        preload: [tenant: t],
        order_by: [asc: t.name]
    )
  end

  def contacts_by_client_ids(tenant_id, ids),
    do:
      Repo.all(
        from c in Contact,
          where: c.tenant_id == ^tenant_id and c.client_id in ^ids,
          order_by: c.name
      )

  def get_contact(tenant_id, client_id),
    do: Repo.get_by(Contact, tenant_id: tenant_id, client_id: client_id)

  def contact_exists?(tenant_id, client_id),
    do:
      Repo.exists?(
        from c in Contact, where: c.tenant_id == ^tenant_id and c.client_id == ^client_id
      )
end
