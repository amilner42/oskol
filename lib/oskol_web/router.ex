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
    plug OskolWeb.Plugs.GuestId, renew: false
    plug :protect_from_forgery
  end

  # Declared before the game routes so `/papi/...` is not captured by
  # `/:slug/:id`.
  scope "/papi", OskolWeb.Api do
    pipe_through :papi

    # Signing in. Every one of these is a POST on purpose: a sign-in is
    # never something a GET does (see OskolWeb.LoginController).
    post "/auth/start", AuthController, :start
    post "/auth/link", AuthController, :link
    post "/auth/code", AuthController, :code
    post "/auth/logout", AuthController, :logout
    get "/me", AuthController, :me
    post "/me/name", AuthController, :rename

    # Practising your own mistakes: an account's deck, or a guest's list.
    get "/practice", PracticeController, :index
    post "/practice/more", PracticeController, :more
    post "/practice/tz", PracticeController, :tz
    post "/practice/bury", PracticeController, :bury

    get "/library", LandingController, :library
    get "/codes/:code", LandingController, :code
    get "/me/prefs", LandingController, :prefs
    post "/me/prefs", LandingController, :save_pref
    get "/me/games", LandingController, :my_games
    get "/games/:slug", LandingController, :show
    post "/games/:slug", LandingController, :create
    get "/games/:slug/rooms/:id", LandingController, :room
    post "/games/:slug/rooms/:id", LandingController, :seat
    get "/games/:slug/rooms/:id/reviews", LandingController, :reviews
    post "/games/:slug/rooms/:id/reviews/retry", LandingController, :retry_review
    get "/games/:slug/rooms/:id/reviews/:game_number", LandingController, :review
    get "/games/:slug/rooms/:id/record", LandingController, :record
    get "/games/:slug/rooms/:id/ratings", LandingController, :ratings

    # Puzzles. A puzzle is open to anyone with the link and costs the
    # analysis engine nothing; what is written down is the deck's, and only
    # for a signed-in browser.
    get "/games/:slug/rooms/:id/puzzles", PuzzleController, :game
    get "/puzzles/:id", PuzzleController, :show
    get "/puzzles/:id/tree", PuzzleController, :tree
    get "/puzzles/:id/mine", PuzzleController, :mine
    post "/puzzles/:id/attempts", PuzzleController, :attempt
    post "/puzzles/:id/attempts/:key/outcome", PuzzleController, :outcome
    # A story link, minted only by the seat that made the mistake, and only
    # ever by a POST: a GET never mints anything.
    post "/puzzles/:id/shares", PuzzleController, :share
  end

  # Enable LiveDashboard in development. Declared before the game routes so
  # `/dev/dashboard` is not captured by `/:slug/:id`.
  if Application.compile_env(:oskol, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OskolWeb.Telemetry

      # What the app would have mailed, to read by eye...
      forward "/mailbox", Plug.Swoosh.MailboxPreview

      # ...and the same sign-in as JSON, for a browser test to click through.
      get "/last-login", OskolWeb.DevController, :last_login
    end
  end

  scope "/", OskolWeb do
    pipe_through :browser

    get "/sitemap.xml", SitemapController, :index

    # The page a mailed sign-in link opens. Declared before "/:slug/:id" so
    # "login" is a reserved word and not a game slug; it reads the token and
    # writes nothing (POST /papi/auth/link is what signs anyone in). A bare
    # "/login" names no game, so it is a 404 like any other unknown slug.
    get "/login/:token", LoginController, :show

    # A puzzle: one position and its question, open to anyone with the
    # link and indexable. Declared before "/:slug" so "puzzles" is a
    # reserved word like "login"; a bare "/puzzles" is a 404 until the
    # practice home lands.
    get "/puzzles/:id", SpaController, :puzzle

    # Games Oskol no longer hosts (see RemovedGameController): every old
    # link to one of them, start page, invite or table, goes home.
    get "/poker", RemovedGameController, :home
    get "/poker/:id", RemovedGameController, :home
    get "/go", RemovedGameController, :home
    get "/go/:id", RemovedGameController, :home
    get "/chess", RemovedGameController, :home
    get "/chess/:id", RemovedGameController, :home

    # The Elm app serves all three; the first two carry the head a crawler
    # reads, the third is a seat at a table and is noindex.
    #
    # The game library
    get "/", SpaController, :library
    # One game's start page, e.g. /backgammon
    get "/:slug", SpaController, :game
    # A running game, e.g. /backgammon/abc123
    get "/:slug/:id", PageController, :play
    # A game played again, turn by turn, with its analysis:
    # /backgammon/abc123/replay. Open to anyone with the link: a replay is
    # what both players and any spectator already saw, and its token (when
    # the link carries one) only says which way the board faces.
    get "/:slug/:id/replay", SpaController, :replay
  end
end
