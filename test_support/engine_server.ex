defmodule Oskol.EngineServer do
  @moduledoc """
  The analysis engine for a browser smoke: a Bandit listener on a local port
  that answers every request the way `Oskol.CompleteEngine` does (every
  legal play of a roll, a clear double and pass for a cube question). A dev
  server whose `ANALYSIS_URL` names this port asks it as it would the real
  engine, so a smoke presses ANALYZE end to end without the network.

  Started by `playwright/test-analysis/setup.exs` in a VM of its own (the
  dev server's VM never compiles `test_support/`):

      Oskol.EngineServer.start(14485, prefer: ["8/5 6/5"], delay_ms: 1500)

  `prefer:` is `Oskol.CompleteEngine`'s; `delay_ms:` holds each answer that
  long, so a page shows its waiting state.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case Keyword.get(opts, :delay_ms, 0) do
      0 -> :ok
      ms -> Process.sleep(ms)
    end

    Oskol.CompleteEngine.respond(conn, opts)
  end

  @doc "Listen on `port` until the VM stops. `{:ok, pid}`."
  def start(port, opts \\ []) do
    Bandit.start_link(
      plug: {__MODULE__, opts},
      port: port,
      ip: {127, 0, 0, 1},
      startup_log: false
    )
  end
end
