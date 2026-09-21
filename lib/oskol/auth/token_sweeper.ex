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
  def init(opts) do
    sweep = Keyword.get(opts, :sweep, &Oskol.Auth.sweep_dead_tokens/1)
    {:ok, %{sweep: sweep}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    run_sweep(state.sweep)
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state), do: handle_continue(:sweep, state)

  defp run_sweep(sweep) do
    case sweep.(@batch_size) do
      retired when is_integer(retired) and retired >= 0 ->
        if retired > 0, do: Logger.info("auth token sweep: retired #{retired} rows")

      _ ->
        Logger.error("auth token sweep failed")
    end
  rescue
    _ -> Logger.error("auth token sweep failed")
  catch
    _, _ -> Logger.error("auth token sweep failed")
  end

  defp schedule, do: Process.send_after(self(), :sweep, @daily_ms)
end
