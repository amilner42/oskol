import Config

# Same credential story as dev.exs: local trust auth or the CI container.
config :oskol, Oskol.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "oskol_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Rooms finish games by the hundred in tests and there is no engine: the
# review queue stays off unless a test turns it on, and every engine call
# goes to a Req.Test stub, never the network.
config :oskol, Oskol.Reviews.Queue, enabled: false

# Signing in is on in tests, and the mail never leaves the process:
# Swoosh.TestAssertions' assert_email_sent is how a test reads it.
config :oskol, :auth_enabled, true
config :oskol, Oskol.Mailer, adapter: Swoosh.Adapters.Test

config :oskol, :analysis,
  url: "http://analysis.test",
  req_options: [plug: {Req.Test, Oskol.Reviews}]

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
