defmodule Callee.PaginationTest do
  use Callee.DataCase, async: true
  alias Callee.{Accounts, Calls, Repo}
  alias Callee.Calls.Call

  setup do
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Org",
        username: "org1",
        password: "password1",
        expires_at: exp
      })

    contacts =
      for i <- 1..45 do
        {:ok, c, _} =
          Accounts.add_contact(t, %{
            "name" => "Person #{String.pad_leading("#{i}", 2, "0")}",
            "mobile" => "70000000#{String.pad_leading("#{i}", 2, "0")}",
            "password" => "pw1234"
          })

        c
      end

    %{tenant: t, contacts: contacts}
  end

  test "contacts paginate and search", %{tenant: t} do
    p1 = Accounts.paginate_contacts_for_tenant(t, %{})
    assert p1.total == 45 and p1.total_pages == 3 and length(p1.entries) == 20
    assert hd(p1.entries).name == "Person 01"

    p3 = Accounts.paginate_contacts_for_tenant(t, %{"page" => "3"})
    assert length(p3.entries) == 5

    # out of range clamps to last page, junk -> 1
    assert Accounts.paginate_contacts_for_tenant(t, %{"page" => "99"}).page == 3
    assert Accounts.paginate_contacts_for_tenant(t, %{"page" => "abc"}).page == 1

    s = Accounts.paginate_contacts_for_tenant(t, %{"q" => "Person 4"})
    assert s.total == 6
    assert Accounts.paginate_contacts_for_tenant(t, %{"q" => "7000000012"}).total == 1
    # LIKE wildcards are escaped
    assert Accounts.paginate_contacts_for_tenant(t, %{"q" => "%"}).total == 0
  end

  test "call history filters", %{tenant: t, contacts: [c1, c2 | _]} do
    insert = fn client_id, caller, status ->
      Repo.insert!(%Call{
        tenant_id: t.id,
        client_id: client_id,
        caller_type: caller,
        status: status
      })
    end

    insert.(c1.client_id, "client", "missed")
    insert.(c1.client_id, "tenant", "completed")
    insert.(c2.client_id, "client", "completed")

    assert Calls.paginate_calls_for_tenant(t.id, %{}).total == 3
    assert Calls.paginate_calls_for_tenant(t.id, %{"filter" => "missed"}).total == 1
    assert Calls.paginate_calls_for_tenant(t.id, %{"filter" => "outgoing"}).total == 1
    assert Calls.paginate_calls_for_tenant(t.id, %{"filter" => "incoming"}).total == 2
    assert Calls.paginate_calls_for_tenant(t.id, %{"filter" => "recorded"}).total == 0
    assert Calls.paginate_calls_for_tenant(t.id, %{"q" => "Person 02"}).total == 1
    assert Calls.missed_count(:tenant, t.id) == 1
    assert Calls.paginate_calls_for_client(c1.client_id, %{"filter" => "missed"}).total == 0
  end

  test "tenant can reset only unshared clients", %{tenant: t, contacts: [c1, c2 | _]} do
    assert {:ok, _} = Accounts.reset_client_password(t, c1.id, "newpass1")
    assert {:ok, _} = Accounts.authenticate_client(c1.client.mobile, "newpass1")

    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t2} =
      Accounts.create_tenant(%{
        name: "Other",
        username: "org2",
        password: "password1",
        expires_at: exp
      })

    {:ok, _, :linked} =
      Accounts.add_contact(t2, %{"name" => "Shared", "mobile" => c2.client.mobile})

    assert {:error, :shared} = Accounts.reset_client_password(t, c2.id, "hijack12")
  end
end
