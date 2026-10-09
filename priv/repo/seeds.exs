# Dev seed: admin / admin1234, plus a demo tenant and client.
alias Callee.Accounts

Accounts.ensure_admin!("admin", "admin1234")

tenant =
  case Accounts.create_tenant(%{
         name: "Demo Tenant",
         username: "tenant1",
         password: "tenant1234",
         expires_at: DateTime.add(DateTime.utc_now(), 365 * 86_400) |> DateTime.truncate(:second)
       }) do
    {:ok, t} -> t
    _ -> Callee.Repo.get_by!(Accounts.Tenant, username: "tenant1")
  end

Accounts.add_contact(tenant, %{
  "name" => "Demo Client",
  "mobile" => "9990001111",
  "password" => "client123"
})
