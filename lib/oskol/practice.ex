defmodule Oskol.Practice do
  @moduledoc """
  Filling the mistakes deck, from Elixir's side.

  Every decision is `src/oskol/practice/sync.gleam`: which mistakes an
  account owns, what order they are introduced in, what is stamped
  afterwards and when a row has been tried enough times. This runs those
  decisions with the real capabilities behind them and says, in one line,
  how it went.

  It is always called **off** whatever asked for it: the review queue's
  task when a game has just been graded, the same queue when a sign-in's
  stamp has committed, its minute sweep for anything the first two missed,
  and `mix oskol.puzzles.sync` by hand. Nothing here belongs in a request
  or in a room's critical path, and nothing here may take a caller down
  with it -- a deck that does not fill is a deck that fills a minute later.
  """

  require Logger

  alias Oskol.Gleam.CtxBuilder

  # How many accounts one sweep works through, mirroring
  # `oskol/practice/sync.sweep_batch`. A Gleam constant is inlined rather
  # than exported, so the number is written twice and changed twice, like
  # the attempt budget in `Oskol.Puzzles`.
  @sweep_batch 60

  @doc """
  Put every mistake this account owns and has not been given into its deck.
  `game_ids` narrows it to those games; `[]` is all of them.
  """
  def sync(user_id, game_ids \\ []) when is_binary(user_id) and is_list(game_ids) do
    case :oskol@practice@sync.sync_deck(CtxBuilder.build(), user_id, game_ids) do
      {:ok, added} ->
        {:ok, added}

      {:error, error} ->
        # Already logged and already written onto the rows it could not
        # place (`sync_failed`), which is what an operator reads and what
        # `--reset` selects on.
        Logger.error("DECK SYNC REFUSED (#{user_id}): #{:oskol@practice@deck.reason(error)}")
        :error
    end
  rescue
    e ->
      # The deck's own exceptions are refusals by the time they get here
      # (`Caps.Practice.unavailable/1`), so this is the last resort and not
      # the usual path. The rows were charged for the try as they were
      # read, so it still runs out rather than looping.
      Logger.error("DECK SYNC FAILED (#{user_id}): #{Exception.message(e)}")
      :error
  end

  @doc """
  Let every row that gave up be tried again -- an operator has fixed
  whatever `deck_error` said. Returns how many were reopened.
  """
  def reset, do: Oskol.Puzzles.reset_deck_attempts()

  @doc """
  The accounts the deck still owes work to, at most `limit` of them: what
  the sweep is about to do, and what its dry run prints. A read.
  """
  def pending(limit \\ sweep_batch()) do
    for {:pending, user_id, game_ids, sources} <-
          :oskol@practice@sync.pending(CtxBuilder.build(), limit) do
      %{user_id: user_id, game_ids: game_ids, sources: sources}
    end
  end

  @doc """
  Sync every account the deck still owes, at most `limit` of them. Returns
  how many accounts were synced and how many cards were new.
  """
  def sweep(limit \\ sweep_batch()) do
    Enum.reduce(pending(limit), %{accounts: 0, added: 0, failed: 0}, fn row, totals ->
      case sync(row.user_id) do
        {:ok, added} -> %{totals | accounts: totals.accounts + 1, added: totals.added + added}
        :error -> %{totals | failed: totals.failed + 1}
      end
    end)
  end

  @doc "How many accounts one sweep works through."
  def sweep_batch, do: @sweep_batch

  @doc """
  This game has just been graded and its puzzles written: give them to the
  accounts whose seats made them.
  """
  def sync_game(game_id) when is_binary(game_id) do
    :oskol@practice@sync.sync_game(CtxBuilder.build(), game_id)
    :ok
  rescue
    e ->
      Logger.error("DECK SYNC FAILED (game #{game_id}): #{Exception.message(e)}")
      :error
  end
end
