defmodule OskolWeb.Router do
  use OskolWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug OskolWeb.Plugs.GuestId
    plug :fetch_live_flash
    plug :put_root_layout, html: {OskolWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # The JSON the Elm client reads. Public, like the pages it replaces: no
  # accounts, no auth. The session is still fetched, because guest identity
  # rides in it (and the cookie plug renews it), and forgery protection is
  # on — the client sends the token in `x-csrf-token`.
  pipeline :papi do
    plug :accepts, ["json"]
    plug :fetch_session
    plug OskolWeb.Plugs.GuestId
    plug :protect_from_forgery
  end

  # Declared before the game routes so `/papi/...` is not captured by
  # `/:slug/:id`.
  scope "/papi", OskolWeb.Api do
    pipe_through :papi

    get "/library", LandingController, :library
    get "/games/:slug", LandingController, :show
    post "/games/:slug", LandingController, :create
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

    get "/sitemap.xml", SitemapController, :index

    # The Elm app serves all three; the first two carry the head a crawler
    # reads, the third is a seat at a table and is noindex.
    #
    # The game library
    get "/", SpaController, :library
    # One game's start page, e.g. /backgammon
    get "/:slug", SpaController, :game
    # A running game, e.g. /backgammon/abc123
    get "/:slug/:id", PageController, :play
  end
end
