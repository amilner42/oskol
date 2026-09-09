defmodule Oskol.Game.Rehydrator do
  @moduledoc """
  Brings a room back from the database when a lookup finds no live process.

  A game is its seed plus its action log: the room is restarted and the
  instance rebuilt by replaying the log through the same gamekit `start` and
  `apply`/`expire` calls that produced it, at the recorded `at_ms` offsets
  shifted so the last applied step lands at the current monotonic time.
  Clocks therefore come back exactly as they stood after the last step — the
  downtime itself charges nobody — and start running again from the moment
  of rehydration.

  Seats (ids, names, tokens) are restored verbatim, so every player's ?t=
  link still opens their seat. Waiting rooms come back as lobbies; finished
  games come back too, read-only in effect (the engine rejects further
  actions), so an old link shows the final position and still offers a
  rematch.
  """
  require Logger

  alias Oskol.Game.GameSupervisor

  @doc "Start a room for a persisted game, or :not_found."
  def resume(game_id) do
    case Oskol.Persistence.fetch(game_id) do
      :not_found ->
        :not_found

      {:ok, game, actions} ->
        case GameSupervisor.restore_game(game_id, game, actions) do
          {:ok, pid} ->
            {:ok, pid}

          # Someone else rehydrated it between our read and our start.
          {:error, {:already_started, pid}} ->
            {:ok, pid}

          other ->
            Logger.error("Could not rehydrate game #{game_id}: #{inspect(other)}")
            :not_found
        end
    end
  rescue
    e in DBConnection.OwnershipError ->
      # Only the test sandbox raises this (a lookup outside a DB-owning
      # test); the answer is the same as no persisted game.
      Logger.debug("rehydration skipped (#{game_id}): #{Exception.message(e)}")
      :not_found

    e ->
      Logger.error("GAME REHYDRATION FAILED (#{game_id}): #{Exception.message(e)}")
      :not_found
  end
end
