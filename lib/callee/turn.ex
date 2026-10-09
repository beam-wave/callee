defmodule Callee.Turn do
  @moduledoc """
  Time-limited TURN credentials for coturn's `use-auth-secret` mode
  (TURN REST API draft). Nothing is stored; coturn recomputes the HMAC.
  """

  # Long enough for very long calls: coturn re-checks this on allocation refresh.
  @ttl 24 * 3600

  def ice_servers(user_label) do
    cfg = Application.get_env(:callee, :turn, [])
    secret = cfg[:secret]
    stun = cfg[:stun_urls] || []
    turn = cfg[:turn_urls] || []

    turn_entry =
      if secret && turn != [] do
        username = "#{System.system_time(:second) + @ttl}:#{user_label}"
        cred = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
        [%{urls: turn, username: username, credential: cred}]
      else
        []
      end

    stun_entry = if stun == [], do: [], else: [%{urls: stun}]
    stun_entry ++ turn_entry
  end
end
