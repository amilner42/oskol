defmodule Oskol.Game.Persister do
  @moduledoc """
  Write-behind persistence for game rooms.

  Rooms cast here and carry on: a database write never blocks gameplay. One
  GenServer serialises the writes, so everything a room casts lands in the
  order it was cast (GenServer casts from one process are delivered in
  order). A failed write logs loudly and is dropped — the room keeps playing
  from memory; what was already written still rehydrates to that point.

  `flush/0` is for tests: it round-trips the queue so every earlier cast has
  been written (or dropped) before it returns.
  """
  use GenServer
  require Logger

  alias Oskol.Persistence

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------- Room-facing API (all casts: never block the room) ----------

  def game_created(game_id, slug, setup) do
    GenServer.cast(__MODULE__, {:write, :game_created, {game_id, slug, config_json(setup)}})
  end

  def game_configured(game_id, setup) do
    GenServer.cast(__MODULE__, {:write, :game_configured, {game_id, config_json(setup)}})
  end

  def players_updated(game_id, players) do
    GenServer.cast(__MODULE__, {:write, :players_updated, {game_id, players}})
  end

  def game_started(game_id, seed, setup, players) do
    GenServer.cast(
      __MODULE__,
      {:write, :game_started, {game_id, seed, config_json(setup), players}}
    )
  end

  def action_applied(game_id, index, kind, player_id, payload, at_ms) do
    GenServer.cast(
      __MODULE__,
      {:write, :action_applied, {game_id, index, kind, player_id, payload, at_ms}}
    )
  end

  def game_finished(game_id, winners) do
    GenServer.cast(__MODULE__, {:write, :game_finished, {game_id, winners}})
  end

  @doc "Wait until every write cast before this call has been handled."
  def flush do
    GenServer.call(__MODULE__, :flush, :timer.seconds(30))
  end

  @doc "The persisted shape of a room's setup (`control` is not serialisable and is rebuilt from the clock preset)."
  def config_json(setup) do
    %{
      "format" => setup.format,
      "selections" => setup.selections,
      "clock" => setup.clock,
      "seed" => setup.seed
    }
  end

  # ---------- Server ----------

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:write, op, args}, state) do
    write(op, args)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  defp write(op, args) do
    do_write(op, args)
  rescue
    e in DBConnection.OwnershipError ->
      # Only the test sandbox raises this: a room outlived its test's
      # connection owner. Not a production condition.
      Logger.debug("game persistence skipped (#{op}): #{Exception.message(e)}")

    e ->
      Logger.error(
        "GAME PERSISTENCE FAILED (#{op} #{inspect(elem(args, 0))}): #{Exception.message(e)}"
      )
  catch
    kind, reason ->
      Logger.error(
        "GAME PERSISTENCE FAILED (#{op} #{inspect(elem(args, 0))}): #{inspect({kind, reason})}"
      )
  end

  defp do_write(:game_created, {game_id, slug, config}),
    do: Persistence.insert_game(game_id, slug, config)

  defp do_write(:game_configured, {game_id, config}),
    do: Persistence.update_config(game_id, config)

  defp do_write(:players_updated, {game_id, players}),
    do: Persistence.update_players(game_id, players)

  defp do_write(:game_started, {game_id, seed, config, players}),
    do: Persistence.mark_started(game_id, seed, config, players)

  defp do_write(:action_applied, {game_id, index, kind, player_id, payload, at_ms}),
    do: Persistence.append_action(game_id, index, kind, player_id, payload, at_ms)

  defp do_write(:game_finished, {game_id, winners}),
    do: Persistence.mark_finished(game_id, winners)
end
