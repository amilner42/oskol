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
  Give every card the place in the queue today's rule would give it:
  worst mistake first, newest game first within a band
  (`oskol/practice/sync.position_of`).

  A one-off. The rows were written when new cards were introduced newest
  game first and nothing else, so a deck filled before that rule changed
  would go on offering a dubious move from this morning ahead of a very
  bad one from last year. Every position is recomputed from the sources
  the card came from, which is exactly what a fresh sync would write.

  It is safe to run twice: a card already in its place is left alone, and
  the second run reports nothing to do. `write?` false reads and changes
  nothing at all.

  Returns `%{accounts:, cards:, moved:}` -- how many decks were looked at,
  how many cards were read, and how many would move (or did).
  """
  def reposition(limit \\ 500, write? \\ false) when is_integer(limit) do
    import Ecto.Query

    Oskol.Repo.all(from(u in Retain.User, order_by: u.id, limit: ^limit, select: u.uid))
    |> Enum.reduce(%{accounts: 0, cards: 0, moved: 0}, fn uid, totals ->
      moves = repositions_for(uid)

      if write? do
        Enum.each(moves.changed, fn {item_id, position} ->
          Oskol.Repo.update_all(
            from(i in Retain.Item, where: i.id == ^item_id),
            set: [position: position]
          )
        end)
      end

      %{
        accounts: totals.accounts + 1,
        cards: totals.cards + moves.read,
        moved: totals.moved + length(moves.changed)
      }
    end)
  end

  # Every card of one deck that is not where today's rule would put it, as
  # {item id, position}. Read in one query per account: a card's band and
  # its recency both come from the `puzzle_sources` rows it was made from,
  # and only the account's own rows count, exactly as the sync counts them.
  defp repositions_for(uid) do
    import Ecto.Query

    rows =
      Oskol.Repo.all(
        from(i in Retain.Item,
          join: u in Retain.User,
          on: u.id == i.user_id,
          join: s in Oskol.Puzzles.Source,
          on: s.puzzle_id == i.key and s.owner_user_id == type(u.uid, Ecto.UUID),
          left_join: r in Oskol.Reviews.Review,
          on: r.game_id == s.game_id and r.game_number == s.game_number,
          where: u.uid == ^uid,
          select: %{
            item: i.id,
            position: i.position,
            grade: s.grade,
            ended_at: coalesce(r.inserted_at, s.inserted_at)
          }
        )
      )

    changed =
      rows
      |> Enum.group_by(& &1.item)
      |> Enum.flat_map(fn {item, sources} ->
        wanted = position_of(sources)
        if Enum.any?(sources, &(&1.position == wanted)), do: [], else: [{item, wanted}]
      end)

    %{read: rows |> Enum.map(& &1.item) |> Enum.uniq() |> length(), changed: changed}
  end

  # The worst of a card's sources decides its band, and the newest within
  # that band decides where it sits inside one -- the same fold
  # `sync.items` makes when a card is first written.
  defp position_of(sources) do
    sources
    |> Enum.min_by(fn source ->
      {:oskol@practice@sync.band_rank(source.grade || ""),
       -DateTime.to_unix(source.ended_at, :millisecond)}
    end)
    |> then(fn source ->
      :oskol@practice@sync.position_of(
        source.grade || "",
        DateTime.to_unix(source.ended_at, :millisecond)
      )
    end)
  end

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
