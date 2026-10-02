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

# Puzzle pictures (`Oskol.Puzzles.Pictures`): the SVG Gleam draws is
# rasterised by librsvg's `rsvg-convert`, on the PATH in the release image
# (the Dockerfile installs `librsvg2-bin`). A laptop without it draws no
# pictures and says so; tests point this at a stub.
config :oskol, :rsvg, path: "rsvg-convert", timeout_ms: 10_000

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

# The analysis board: positions asked of the engine on a player's press
# (`oskol/handlers/analysis`). A guest an hour and a day, an account an hour
# and a day, everybody a day; a position already analyzed costs nothing.
# 600 a day is at most 30 engine-minutes. Per node and in memory, like the
# sign-in limits: a restart starts the day's counts again.
config :oskol, :analysis_budget,
  guest_hour: 10,
  guest_day: 30,
  user_hour: 30,
  user_day: 150,
  global_day: 600

# The line those asks wait in (`Oskol.Analysis.Asker`): two at once, twenty
# waiting, a minute's pause after the engine fails.
config :oskol, Oskol.Analysis.Asker,
  enabled: true,
  in_flight: 2,
  waiting: 20,
  circuit_ms: 60_000,
  ask_timeout_ms: 60_000

# The puzzle deck's spaced repetition (the `retain` library): our repo, our
# tables, no processes to start.
#
# The ladder is the brief's: a miss comes back tomorrow, then 1, 3, 7, 21, 58,
# 145 and 365 days. Level 0 is one day rather than retain's default zero,
# because a puzzle you just got wrong should come back tomorrow, not later in
# the same session -- the player is still looking at the answer.
config :retain,
  repo: Oskol.Repo,
  intervals: [1, 1, 3, 7, 21, 58, 145, 365]

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

# Sage, the bot a player can sit down against. How deep it searches is the
# knob worth having: 4-ply is what a review reads a game at, and a single
# position at that depth is a couple of seconds and occasionally most of the
# twelve a backgammon turn gets free. Turning it down makes every bot on the
# site answer faster and play worse. The ladder is how long to wait before
# asking an engine that did not answer again; the game gives up after the
# last rung and offers the human the game rather than a board that never
# moves.
config :oskol, :bot,
  move_level: "4ply",
  cube_level: "4ply",
  retry_ms: [5_000, 20_000, 60_000],
  ask_timeout_ms: :timer.seconds(30)

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
