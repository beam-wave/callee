import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :callee, Callee.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "callee_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :callee, CalleeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "eYlYFP9F7dipRoHYW5MYf1RrUqFzFlJEhOht6w7mY1ZTYtT+NUh+VFGdxo7ZDVTP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :callee,
  run_boot: false,
  push_enabled: false,
  ring_timeout_ms: 300,
  skip_bucket_check: true

config :bcrypt_elixir, log_rounds: 4
config :callee, recording_mode: "off", reconnect_grace_ms: 150, client_upload_grace_ms: 50
