defmodule Oskol.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Capture crashed process exceptions
    #  - refer to: https://oskol.sentry.io/insights/projects/oskol/getting-started
    :logger.add_handler(:my_sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    # In prod the pending migrations run before the tree comes up: no
    # release_command in fly.toml, and a machine waking from a stopped
    # state always matches the schema its code expects.
    if Application.get_env(:oskol, :migrate_on_boot, false), do: Oskol.Release.migrate()

    children = [
      OskolWeb.Telemetry,
      Oskol.Repo,
      {DNSCluster, query: Application.get_env(:oskol, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Oskol.PubSub},
      {Registry, keys: :unique, name: Oskol.GameRegistry},
      # The persister must outlive and precede the rooms that cast to it.
      {Oskol.Game.Persister, []},
      Oskol.Game.GameSupervisor,
      {Oskol.Game.Pruner, []},
      # Start a worker by calling: Oskol.Worker.start_link(arg)
      # {Oskol.Worker, arg},
      # Start to serve requests, typically the last entry
      OskolWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Oskol.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OskolWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
