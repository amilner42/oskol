import Config

# Same credential story as dev.exs: local trust auth or the CI container.
config :oskol, Oskol.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "oskol_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# No periodic pruning during tests; `Oskol.Game.Pruner.prune_now/0` runs it.
config :oskol, :prune_interval_ms, nil

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :oskol, OskolWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qCKjwIgosqIZGDZ1nIAteZTqzVFF9z7iQm7eJa4RfgMWLQLnOZuYSnBNgTgEvNY9",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
