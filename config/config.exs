# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :oskol,
  ecto_repos: [Oskol.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :oskol, OskolWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: OskolWeb.ErrorHTML, json: OskolWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Oskol.PubSub,
  live_view: [signing_salt: "rNcvke8W"]

# Mail. One mailer, one mail (the sign-in link and code): Postmark in
# production, the local mailbox in development, nothing at all under test.
# Swoosh's HTTP goes through Req, which is already here for the analysis
# engine, so no second HTTP client comes along.
config :swoosh, api_client: Swoosh.ApiClient.Req

config :oskol, Oskol.Mailer, adapter: Swoosh.Adapters.Local

config :oskol, :mail_from, "hello@oskol.io"

# The only mail Oskol sends is a sign-in link/code. These fixed-window
# ceilings are deliberately small for today's traffic: one running node can
# send up to 200 messages in its 24-hour window (about 6,000/month if it stays
# up, below Postmark's 10,000-message $15/month plan). ETS resets on a deploy
# or restart, so this is a best-effort spend guard, not a durable billing cap.
# Change them in runtime config, not in the handler. Source means a per-boot
# HMAC key derived only from Fly-Client-IP; without that trusted header, Oskol
# omits the source bucket. Oskol never stores or logs a raw IP.
config :oskol, :auth_mail_budget,
  guest: [limit: 10, window_s: 3_600],
  address: [limit: 30, window_s: 3_600],
  source: [limit: 20, window_s: 3_600],
  global: [limit: 200, window_s: 86_400]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  default: [
    args: ~w(./build.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  oskol: [
    args: ~w(./build.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  oskol: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
