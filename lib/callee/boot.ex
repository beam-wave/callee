defmodule Callee.Boot do
  @moduledoc "One-shot startup work."
  require Logger

  def run do
    if Application.get_env(:callee, :run_boot, true), do: do_run()
  end

  defp do_run do
    # Live call state is in memory; anything left over from before a restart is dead.
    {n, _} = Callee.Calls.close_orphaned_calls()
    if n > 0, do: Logger.info("closed #{n} orphaned calls")

    with u when is_binary(u) <- System.get_env("ADMIN_USERNAME"),
         p when is_binary(p) <- System.get_env("ADMIN_PASSWORD") do
      Callee.Accounts.ensure_admin!(u, p)
    end

    unless Application.get_env(:callee, :skip_bucket_check), do: Callee.Storage.ensure_bucket()
    Callee.Push.vapid_keys()
  rescue
    e -> Logger.error("boot task failed: #{Exception.message(e)}")
  end
end
