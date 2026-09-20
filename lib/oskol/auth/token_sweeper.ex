defmodule Oskol.Auth.TokenSweeper do
  @moduledoc """
  Supervised daily housekeeping for sign-in rows. Each pass is bounded, so a
  backlog cannot monopolise Postgres; tomorrow's pass continues where it left
  off. It logs only a count, never an address, token, or request IP.
  """
  use GenServer
  require Logger

  @daily_ms :timer.hours(24)
  @batch_size 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    retired = Oskol.Auth.sweep_dead_tokens(@batch_size)
    if retired > 0, do: Logger.info("auth token sweep: retired #{retired} rows")
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @daily_ms)
end
