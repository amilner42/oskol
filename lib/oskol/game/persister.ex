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

  def game_started(game_id, seed, setup, players, state) do
    GenServer.cast(
      __MODULE__,
      {:write, :game_started, {game_id, seed, config_json(setup), players, state}}
    )
  end

  # `state` is where the game stands after this step (GameKit.summary/1),
  # written beside the log entry so the row always says what the log does.
  def action_applied(game_id, index, kind, player_id, payload, at_ms, state) do
    GenServer.cast(
      __MODULE__,
      {:write, :action_applied, {game_id, index, kind, player_id, payload, at_ms, state}}
    )
  end

  @doc """
  A room rebuilt from its log writes where it stands, so a row from before
  the snapshot existed is right after one wake.
  """
  def state_mirrored(game_id, state) do
    GenServer.cast(__MODULE__, {:write, :state_mirrored, {game_id, state}})
  end

  @doc """
  A game of this room ended, so an analysis may be owed. Written here
  rather than from the room so it lands in order behind the actions the
  analysis will read, and so a test without a sandbox owner skips it like
  every other write.
  """
  def analysis_owed(game_id) do
    GenServer.cast(__MODULE__, {:write, :analysis_owed, {game_id}})
  end

  def game_finished(game_id, winners) do
    GenServer.cast(__MODULE__, {:write, :game_finished, {game_id, winners}})
  end

  @doc """
  A browser signed in: hand its seats to the account and move them to its
  fresh guest id (`Oskol.Auth.adopt_seats/3`, one transaction with the
  guest row).

  The one write here that is a `call`, and the one a room did not ask for.
  It is a call because the answer — how many seats the account gained, and
  which rooms changed — is what the page says and what tells the live rooms;
  and it goes through the persister rather than straight to the database so
  that it lands *behind* everything the rooms have already queued. A direct
  UPDATE would race a room rewriting `players` for a seat claim, and the
  loser of that race silently unowns a seat.
  """
  def stamp_seats(old_guest_id, new_guest_id, user_id) do
    GenServer.call(
      __MODULE__,
      {:stamp_seats, old_guest_id, new_guest_id, user_id},
      :timer.seconds(60)
    )
  catch
    # Still queued behind the rooms' writes, so it will most likely land:
    # the caller treats the browser as moved (the other choice, keeping the
    # old id, would strand every seat on an id the write then hands away).
    :exit, {:timeout, _} -> :pending
  end

  @doc "Wait until every write cast before this call has been handled."
  def flush do
    GenServer.call(__MODULE__, :flush, :timer.seconds(30))
  end

  @doc "The persisted shape of a room's setup (`control` is not serialisable and is rebuilt from the clock preset)."
  def config_json(setup) do
    %{
      "format" => setup.format,
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
  def handle_call({:stamp_seats, old_guest_id, new_guest_id, user_id}, _from, state) do
    # A failed sign-in write must not take the persister down with it: its
    # mailbox is every room's queued write-behind.
    reply =
      try do
        Oskol.Auth.adopt_seats(old_guest_id, new_guest_id, user_id)
      rescue
        e ->
          Logger.error("SIGN-IN STAMP FAILED: #{Exception.message(e)}")
          :error
      end

    # The seats are the account's as of this moment, so its mistakes are
    # too. Asked here and not from the sign-in handler because *here* is
    # where the transaction committed: the caller may have timed out
    # waiting (`stamp_seats/3` answers `:pending` after a minute) and gone
    # home, and the deck must fill anyway. A cast, so nothing about a deck
    # is ever in front of a room's queued writes.
    with {:ok, {stamped, _game_ids}} when stamped > 0 <- reply do
      Oskol.Reviews.Queue.sync_deck(user_id)
    end

    {:reply, reply, state}
  end

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

  defp do_write(:analysis_owed, {game_id}),
    do: Oskol.Reviews.mark_analysis_owed(game_id)

  defp do_write(:game_created, {game_id, slug, config}),
    do: Persistence.insert_game(game_id, slug, config)

  defp do_write(:game_configured, {game_id, config}),
    do: Persistence.update_config(game_id, config)

  defp do_write(:players_updated, {game_id, players}),
    do: Persistence.update_players(game_id, players)

  defp do_write(:game_started, {game_id, seed, config, players, state}),
    do: Persistence.mark_started(game_id, seed, config, players, state)

  defp do_write(:action_applied, {game_id, index, kind, player_id, payload, at_ms, state}),
    do: Persistence.append_action(game_id, index, kind, player_id, payload, at_ms, state)

  defp do_write(:state_mirrored, {game_id, state}),
    do: Persistence.mirror_state(game_id, state)

  defp do_write(:game_finished, {game_id, winners}),
    do: Persistence.mark_finished(game_id, winners)
end
