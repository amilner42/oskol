defmodule Oskol.Game.Pruner do
  @moduledoc """
  Periodically deletes unfinished games (and their action logs) that nobody
  has touched for 3 days. Finished games are kept: they are small and they
  let an old link say "game over" instead of nothing.
  """
  use GenServer
  require Logger

  @default_interval :timer.hours(6)
  @max_age_days 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one prune pass now (tests). Returns the number of games deleted."
  def prune_now, do: GenServer.call(__MODULE__, :prune)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    prune()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:prune, _from, state), do: {:reply, prune(), state}

  defp prune do
    count = Oskol.Persistence.prune_unfinished(@max_age_days)
    if count > 0, do: Logger.info("Pruned #{count} unfinished games")
    count
  rescue
    e ->
      Logger.error("GAME PRUNING FAILED: #{Exception.message(e)}")
      0
  end

  defp schedule do
    case Application.get_env(:oskol, :prune_interval_ms, @default_interval) do
      nil -> :ok
      ms -> Process.send_after(self(), :prune, ms)
    end
  end
end
