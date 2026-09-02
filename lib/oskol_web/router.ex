defmodule OskolWeb.Router do
  use OskolWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OskolWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Enable LiveDashboard in development. Declared before the game routes so
  # `/dev/dashboard` is not captured by `/:slug/:id`.
  if Application.compile_env(:oskol, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OskolWeb.Telemetry
    end
  end

  scope "/", OskolWeb do
    pipe_through :browser

    # The game library
    live "/", LandingLive, :library
    # One game's start page and lobby, e.g. /tilt
    live "/:slug", LandingLive, :game
    # A running game, e.g. /tilt/abc123
    get "/:slug/:id", PageController, :play
  end
end
