defmodule Oskol.Auth.Limiter do
  @moduledoc """
  The counters behind the sign-in rate limits: one ETS table of
  `{key, window_start, count}`, bumped through the `count` capability.

  The handler owns every number (`src/oskol/handlers/auth.gleam`): how many
  starts a browser gets, how many an address gets, and how long a window is.
  This only counts, in a fixed window that resets when it runs out.

  **Per node.** Oskol runs on one machine, and a second would give each its
  own allowance. That is fine for what this protects — the point is a
  ceiling on how much mail one abuser can make us send, not an exact figure.
  Nothing here is a security control on its own: a token is still hashed,
  single use, fifteen minutes and five tries.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Bump `key` and answer how many it holds inside the current window, this one
  included. A window that has run out starts again at one.
  """
  def count(key, window_s) when is_binary(key) and is_integer(window_s) and window_s > 0 do
    ensure_table()
    now = System.system_time(:second)

    # One atomic step per call: two requests racing on one key both count.
    case :ets.lookup(@table, key) do
      [{^key, started, _}] when now - started < window_s ->
        :ets.update_counter(@table, key, {3, 1})

      _ ->
        :ets.insert(@table, {key, now, 1})
        1
    end
  rescue
    # A counter is never worth a 500. Failing open costs at most some mail.
    _ -> 1
  end

  @doc "Forget every count. Tests only."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  # Keys nobody has touched for a day are dead weight: an abuser's address
  # is not worth remembering, and the table must not grow forever.
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - 86_400
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.hours(1))

  # The table belongs to whoever gets there first: the supervised process on
  # boot, or the first caller in a test that runs without the tree.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
