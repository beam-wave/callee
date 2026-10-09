import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/callee start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :callee, CalleeWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :callee, Callee.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :callee, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :callee, CalleeWeb.Endpoint,
    url: [
      host: host,
      port: String.to_integer(System.get_env("PHX_URL_PORT") || "443"),
      scheme: System.get_env("PHX_URL_SCHEME") || "https"
    ],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  case System.get_env("CHECK_ORIGIN") do
    nil -> :ok
    "false" -> config :callee, CalleeWeb.Endpoint, check_origin: false
    list -> config :callee, CalleeWeb.Endpoint, check_origin: String.split(list, ",", trim: true)
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :callee, CalleeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :callee, CalleeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# ---- Callee app config (all environments) ----
split = fn
  nil -> []
  "" -> []
  s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

config :callee, :turn,
  secret: System.get_env("TURN_SECRET", "dev-turn-secret-change-me"),
  stun_urls: split.(System.get_env("STUN_URLS", "stun:localhost:3478")),
  turn_urls:
    split.(
      System.get_env(
        "TURN_URLS",
        "turn:localhost:3478?transport=udp,turn:localhost:3478?transport=tcp"
      )
    )

config :callee,
  # client | server | off  (server = media flows through Phoenix and is recorded there)
  recording_mode:
    System.get_env("RECORDING_MODE", if(config_env() == :test, do: "off", else: "server")),
  recording_dir:
    System.get_env("RECORDING_DIR", Path.join(System.tmp_dir!(), "callee-recordings")),
  max_call_hours: String.to_integer(System.get_env("MAX_CALL_HOURS", "8")),
  # Max people in a group call, including the tenant.
  group_max: String.to_integer(System.get_env("GROUP_MAX", "50")),
  # Loudest speakers forwarded to each listener in group calls.
  speaker_slots: String.to_integer(System.get_env("SPEAKER_SLOTS", "4")),
  # A group call with only the host left on it ends after this long.
  group_idle_ms:
    if(config_env() == :test,
      do: 300,
      else: String.to_integer(System.get_env("GROUP_IDLE_MINUTES", "10")) * 60_000
    ),
  # UDP ports the server media engine uses for ICE host candidates (server mode).
  media_port_range: System.get_env("MEDIA_PORT_RANGE", "50000-50100"),
  s3_bucket: System.get_env("S3_BUCKET", "callee-recordings"),
  # Optional key prefix when sharing a bucket with other apps, e.g. "callee".
  s3_prefix: System.get_env("S3_PREFIX"),
  # Skip creating/checking the bucket at boot (keys without ListBucket/CreateBucket).
  skip_bucket_check: System.get_env("SKIP_BUCKET_CHECK") in ~w(1 true) or config_env() == :test,
  # Blank = S3 is internal-only; recordings are streamed through the app.
  s3_public_endpoint:
    (case System.get_env(
            "S3_PUBLIC_ENDPOINT",
            if(config_env() == :dev, do: "http://localhost:8333")
          ) do
       "" -> nil
       v -> v
     end),
  # Blank (as docker compose passes unset vars) = generate and store in the DB.
  vapid_public_key:
    (case System.get_env("VAPID_PUBLIC_KEY") do
       "" -> nil
       v -> v
     end),
  vapid_private_key:
    (case System.get_env("VAPID_PRIVATE_KEY") do
       "" -> nil
       v -> v
     end),
  vapid_subject: System.get_env("VAPID_SUBJECT", "mailto:admin@example.com"),
  # Firebase service-account JSON (file path, raw JSON or base64). Blank = FCM off.
  fcm_service_account: System.get_env("FCM_SERVICE_ACCOUNT")

s3_overrides =
  case System.get_env("S3_ENDPOINT", if(config_env() == :dev, do: "http://localhost:8333")) do
    # unset or blank = real AWS S3 (regional endpoint chosen by ExAws)
    v when v in [nil, ""] ->
      []

    url ->
      %URI{scheme: s, host: h, port: p} = URI.parse(url)
      [scheme: "#{s}://", host: h, port: p]
  end

config :ex_aws,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "calleeaccess"),
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "calleesecret"),
  region: System.get_env("AWS_REGION", "us-east-1")

config :ex_aws, :s3, [region: System.get_env("AWS_REGION", "us-east-1")] ++ s3_overrides
