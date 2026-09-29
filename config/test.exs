import Config

# How many partitions `bin/test-par` is running (1 for a plain `mix test`).
# The pool below and ExUnit's max_cases in test/test_helper.exs both divide
# by it, so total concurrency across partitions stays what one run would use.
test_partitions = String.to_integer(System.get_env("MIX_TEST_PARTITIONS") || "1")

# Same credential story as dev.exs: local trust auth or the CI container.
config :oskol, Oskol.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: "oskol_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # One checkout per test running at once, so the pool wants to be as wide as
  # ExUnit is concurrent. `bin/test-par` runs several partitions against one
  # Postgres, and max_connections (100 out of the box) is a ceiling they
  # share: partitions that each size a pool for the whole machine exhaust it,
  # and the ones that lose the race die with "too many clients already" --
  # some before creating their database, so their share of the suite never
  # runs and the totals still read green. Divide the machine instead.
  pool_size: max(div(System.schedulers_online() * 2, test_partitions), 6)

# Rooms finish games by the hundred in tests and there is no engine: the
# review queue stays off unless a test turns it on, and every engine call
# goes to a Req.Test stub, never the network.
config :oskol, Oskol.Reviews.Queue, enabled: false

# Puzzle pictures are rasterised by a binary tests never depend on: this
# stub writes a fixed PNG for any SVG (test_support/fake_rsvg_convert).
config :oskol, :rsvg,
  path: Path.expand("../test_support/fake_rsvg_convert", __DIR__),
  timeout_ms: 5_000

# The sign-in mail never leaves the process in tests:
# Swoosh.TestAssertions' assert_email_sent is how a test reads it.
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
