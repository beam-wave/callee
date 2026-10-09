defmodule Callee.Calls do
  @moduledoc """
  Call history + entry points into the live call state machine (`Callee.Calls.CallServer`).

  Parties are identified as `{:tenant, id}` or `{:client, id}`.
  """
  import Ecto.Query
  alias Callee.Repo
  alias Callee.Accounts
  alias Callee.Accounts.Tenant
  alias Callee.Pagination
  alias Callee.Calls.{Call, Recording, CallServer, Participant}

  @pubsub Callee.PubSub

  ## Topics

  @doc "Signalling topic for a party (all their open tabs join it)."
  def user_topic({type, id}), do: "user:#{type}:#{id}"

  @doc "PubSub topic LiveViews use to refresh history."
  def history_topic({type, id}), do: "history:#{type}:#{id}"

  def subscribe_history(party), do: Phoenix.PubSub.subscribe(@pubsub, history_topic(party))

  def notify_history(%{id: id} = call) do
    for {_, pid} = p <- [{:tenant, call.tenant_id}, {:client, call.client_id}],
        pid != nil,
        do: Phoenix.PubSub.broadcast(@pubsub, history_topic(p), {:call_updated, id})

    :ok
  end

  ## Live call API

  @doc """
  Start a call from `caller` to `callee`. Validates the pair is in an address book
  and the tenant is active.
  """
  def start_call(caller, callee, device_id, channel_pid) do
    {tenant_id, client_id} = pair(caller, callee)

    with %Tenant{} = tenant <- Accounts.get_tenant(tenant_id) || {:error, :not_found},
         true <- Tenant.active?(tenant) || {:error, :tenant_inactive},
         true <- Accounts.contact_exists?(tenant_id, client_id) || {:error, :not_in_contacts} do
      {:ok, call} =
        %Call{
          tenant_id: tenant_id,
          client_id: client_id,
          caller_type: to_string(elem(caller, 0)),
          status: "ringing"
        }
        |> Repo.insert()

      case DynamicSupervisor.start_child(
             Callee.CallSupervisor,
             {CallServer,
              call: call, caller: caller, callee: callee, device: device_id, pid: channel_pid}
           ) do
        {:ok, _pid} ->
          notify_history(call)
          {:ok, call}

        {:error, {:busy, who}} ->
          {:ok, call} = finish(call, "busy", "#{who}_busy")
          {:error, :busy, call}

        {:error, reason} ->
          finish(call, "failed", inspect(reason))
          {:error, :failed}
      end
    end
  end

  @doc "Call a saved group (members still in the address book)."
  def start_saved_group_call({:tenant, tid} = host, group_id, device_id, channel_pid) do
    case Callee.Groups.get(tid, group_id) do
      nil ->
        {:error, :not_found}

      g ->
        ids = g |> Callee.Groups.members_with_names() |> Enum.map(&elem(&1, 0))
        start_group_call(host, ids, device_id, channel_pid, group: g)
    end
  end

  defdelegate joinable_group_calls(party), to: Callee.Calls.GroupCallServer, as: :joinable_for
  defdelegate ring_again(call_id, host, client_id), to: Callee.Calls.GroupCallServer

  @doc """
  Tenant starts a group call with several of its clients.
  Returns {:ok, call} | {:error, reason}.
  """
  def start_group_call(host, client_ids, device_id, channel_pid, opts \\ [])

  def start_group_call({:tenant, tid} = host, client_ids, device_id, channel_pid, opts) do
    group = Keyword.get(opts, :group)
    max = Application.get_env(:callee, :group_max, 50)
    ids = client_ids |> Enum.map(&to_int/1) |> Enum.uniq()

    with %Tenant{} = tenant <- Accounts.get_tenant(tid) || {:error, :not_found},
         true <- Tenant.active?(tenant) || {:error, :tenant_inactive},
         true <- (length(ids) >= 2 and length(ids) <= max - 1) || {:error, :bad_group_size},
         contacts = Accounts.contacts_by_client_ids(tid, ids),
         true <- length(contacts) == length(ids) || {:error, :not_in_contacts} do
      {:ok, call} =
        %Call{
          tenant_id: tid,
          client_id: nil,
          kind: "group",
          group_id: group && group.id,
          caller_type: "tenant",
          status: "ringing"
        }
        |> Repo.insert()

      invitees = Enum.map(contacts, &{&1.client_id, &1.name})

      case DynamicSupervisor.start_child(
             Callee.CallSupervisor,
             {Callee.Calls.GroupCallServer,
              call: call,
              host: host,
              device: device_id,
              pid: channel_pid,
              invitees: invitees,
              group_name: group && group.name}
           ) do
        {:ok, _} ->
          notify_history(call)
          {:ok, call}

        {:error, :all_busy} ->
          finish(call, "busy", "all_busy")
          {:error, :all_busy}

        {:error, {:busy, _}} ->
          finish(call, "busy", "caller_busy")
          {:error, :busy}

        {:error, reason} ->
          finish(call, "failed", inspect(reason))
          {:error, :failed}
      end
    end
  end

  defp to_int(i) when is_integer(i), do: i
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp pair({:tenant, t}, {:client, c}), do: {t, c}
  defp pair({:client, c}, {:tenant, t}), do: {t, c}

  defdelegate accept(call_id, party, device_id, pid), to: CallServer
  defdelegate reject(call_id, party), to: CallServer
  defdelegate hangup(call_id, party), to: CallServer
  defdelegate signal(call_id, party, device_id, data), to: CallServer
  defdelegate active_call_for(party), to: CallServer
  defdelegate mark_reached(call_id), to: CallServer
  defdelegate rebind(call_id, party, device, pid), to: CallServer

  ## Persistence (called by CallServer)

  def mark_active(%Call{} = call) do
    {:ok, call} =
      call
      |> Call.changeset(%{status: "active", answered_at: DateTime.utc_now()})
      |> Repo.update()

    notify_history(call)
    {:ok, call}
  end

  def finish(%Call{} = call, status, reason) do
    now = DateTime.utc_now()
    dur = if call.answered_at, do: DateTime.diff(now, call.answered_at), else: 0

    {:ok, call} =
      call
      |> Call.changeset(%{
        status: status,
        end_reason: reason,
        ended_at: now,
        duration_seconds: dur
      })
      |> Repo.update()

    notify_history(call)
    {:ok, call}
  end

  @doc "Calls left in ringing/active after a crash or restart are closed on boot."
  def close_orphaned_calls do
    from(c in Call, where: c.status in ["ringing", "active"])
    |> Repo.update_all(
      set: [status: "failed", end_reason: "server_restart", ended_at: DateTime.utc_now()]
    )
  end

  ## History

  @doc """
  Tenant call history. opts: q (contact name/mobile),
  filter (all|missed|incoming|outgoing|recorded), page.
  Entries are `{call, contact_name}`.
  """
  def paginate_calls_for_tenant(tenant_id, opts) do
    query =
      from c in Call,
        as: :call,
        where: c.tenant_id == ^tenant_id,
        left_join: cl in assoc(c, :client),
        as: :client,
        left_join: r in assoc(c, :recording),
        as: :rec,
        left_join: ct in Callee.Accounts.Contact,
        as: :contact,
        on: ct.tenant_id == c.tenant_id and ct.client_id == c.client_id,
        order_by: [desc: c.inserted_at],
        preload: [recording: r, client: cl, participants: :client, group: []],
        select: {c, ct.name}

    query =
      case search(opts["q"]) do
        nil ->
          query

        q ->
          # direct: contact name/mobile; group: any participant's contact name/mobile
          where(
            query,
            [contact: ct, client: cl],
            ilike(ct.name, ^q) or ilike(cl.mobile, ^q) or
              exists(
                from p in Participant,
                  join: pc in Callee.Accounts.Client,
                  on: pc.id == p.client_id,
                  left_join: pct in Callee.Accounts.Contact,
                  on: pct.client_id == p.client_id and pct.tenant_id == ^tenant_id,
                  where:
                    p.call_id == parent_as(:call).id and
                      (ilike(pct.name, ^q) or ilike(pc.mobile, ^q))
              )
          )
      end

    query
    |> filter_calls(opts["filter"], "tenant")
    |> Pagination.paginate(opts["page"], 15)
  end

  def paginate_calls_for_client(client_id, opts) do
    query =
      from c in Call,
        as: :call,
        where:
          c.client_id == ^client_id or
            exists(
              from p in Participant,
                where: p.call_id == parent_as(:call).id and p.client_id == ^client_id
            ),
        join: t in assoc(c, :tenant),
        as: :tenant,
        order_by: [desc: c.inserted_at],
        preload: [
          tenant: t,
          group: [],
          participants: ^from(p in Participant, where: p.client_id == ^client_id)
        ]

    query =
      case search(opts["q"]) do
        nil -> query
        q -> where(query, [tenant: t], ilike(t.name, ^q))
      end

    query
    |> client_filter(opts["filter"], client_id)
    |> Pagination.paginate(opts["page"], 15)
  end

  defp search(nil), do: nil
  defp search(q), do: if(String.trim(q) == "", do: nil, else: Pagination.like(String.trim(q)))

  defp client_filter(q, "missed", cid) do
    where(
      q,
      [call: c],
      (c.kind == "direct" and c.status in ["missed", "rejected", "busy"] and
         c.caller_type != "client") or
        (c.kind == "group" and
           exists(
             from p in Participant,
               where:
                 p.call_id == parent_as(:call).id and p.client_id == ^cid and
                   p.status in ["missed", "declined", "busy"]
           ))
    )
  end

  defp client_filter(q, f, _cid), do: filter_calls(q, f, "client")

  defp filter_calls(q, "missed", me),
    do: where(q, [call: c], c.status in ["missed", "rejected", "busy"] and c.caller_type != ^me)

  defp filter_calls(q, "group", _), do: where(q, [call: c], c.kind == "group")

  defp filter_calls(q, "incoming", me), do: where(q, [call: c], c.caller_type != ^me)
  defp filter_calls(q, "outgoing", me), do: where(q, [call: c], c.caller_type == ^me)
  defp filter_calls(q, "recorded", _), do: where(q, [rec: r], not is_nil(r.id))
  defp filter_calls(q, _, _), do: q

  @doc "Missed incoming calls since a timestamp (for the badge)."
  def missed_count(party_type, id) do
    {field, me} =
      if party_type == :tenant, do: {:tenant_id, "tenant"}, else: {:client_id, "client"}

    since = DateTime.add(DateTime.utc_now(), -7 * 86_400)

    direct =
      Repo.aggregate(
        from(c in Call,
          where:
            field(c, ^field) == ^id and c.status == "missed" and c.caller_type != ^me and
              c.inserted_at > ^since
        ),
        :count
      )

    group =
      if party_type == :client,
        do:
          Repo.aggregate(
            from(p in Participant,
              where: p.client_id == ^id and p.status == "missed" and p.inserted_at > ^since
            ),
            :count
          ),
        else: 0

    direct + group
  end

  def get_call(id), do: Repo.get(Call, id)

  ## Recordings (tenant only)

  def get_recording_for_tenant(tenant_id, recording_id),
    do: Repo.get_by(Recording, id: recording_id, tenant_id: tenant_id, status: "ready")

  def create_recording(%Call{} = call, attrs) do
    %Recording{call_id: call.id, tenant_id: call.tenant_id}
    |> Recording.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :call_id)
  end

  def update_recording(%Recording{} = r, attrs) do
    {:ok, r} = r |> Recording.changeset(attrs) |> Repo.update()

    Phoenix.PubSub.broadcast(
      @pubsub,
      history_topic({:tenant, r.tenant_id}),
      {:call_updated, r.call_id}
    )

    {:ok, r}
  end
end
