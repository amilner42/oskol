defmodule Oskol.Repo.Migrations.BoundDeckSync do
  use Ecto.Migration

  @moduledoc """
  What the deck sync needs on top of the store (the `puzzles-deck` ticket).

  `deck_synced_at` already says a source is in its owner's deck. These two
  columns say what happened when it is not: how many times we have tried to
  put it there, and why the last try failed. A sync that cannot be made to
  work would otherwise have the minute sweep replaying it for ever without
  ever saying so -- the same bound, and the same reason for it, as the
  extraction attempts on `game_reviews`.

  The GIN index is the partial one from `IndexSeatedRooms` without its
  predicate: that one covers only rooms a player can resume, and every game
  a puzzle comes from is over. A guest's practice session is "the mistakes
  on the seats this cookie holds", which is that containment test against
  finished rooms.
  """

  def change do
    alter table(:puzzle_sources) do
      # Tries spent getting this row into a deck. Charged as it is read for
      # a sync, so a crash mid-write cannot refund it.
      add(:deck_attempts, :integer, null: false, default: 0)
      # Why the last try failed; what an operator looks for.
      add(:deck_error, :string)
    end

    # The sweep's question, and the shape it asks it in: rows no deck holds
    # that still have tries left.
    create(
      index(:puzzle_sources, [:deck_attempts],
        where: "deck_synced_at IS NULL AND puzzle_id IS NOT NULL",
        name: :puzzle_sources_unsynced
      )
    )

    create(
      index(:games, ["oskol_players_jsonb(players) jsonb_path_ops"],
        using: :gin,
        name: :games_players_gin
      )
    )
  end
end
