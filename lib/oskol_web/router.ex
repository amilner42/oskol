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

  scope "/", OskolWeb do
    pipe_through :browser

    live "/", LandingLive
    get "/:id", PageController, :elm_game
  end

  # Other scopes may use custom stacks.
  scope "/api", OskolWeb do
    pipe_through :api

    get "/gleam/hello", GleamController, :hello
    get "/gleam/hello/:name", GleamController, :hello_name
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:oskol, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OskolWeb.Telemetry
    end
  end
end
