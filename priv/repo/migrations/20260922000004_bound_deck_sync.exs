defmodule Oskol.Repo.Migrations.BoundDeckSync do
  use Ecto.Migration

  @moduledoc """
  What the deck sync needs on top of the store (the `puzzles-deck` ticket).

  `owner_user_id` is the account whose seat made this mistake, derived from
  `games.players[seat].user_id` when the sources are written and again when
  a sign-in stamps that game's seats. It is an index key and nothing more:
  who may open a seat is still `src/oskol/rooms/seat.gleam`, asked in Gleam
  of every row the queries hand back.

  It exists because the sweep's question is "mistakes an account owns that
  its deck does not hold", and without the column that is a lateral join
  over every unsynced row, every minute, for ever -- **a guest's mistakes
  are never synced**, so the unsynced set grows without bound as guests
  play. With it, the sweep reads one partial index that holds only the rows
  actually owed.

  `deck_attempts` and `deck_error` say what happened when a sync did not
  work: how many times it has been tried, and why the last one failed. A
  sync that cannot be made to work would otherwise have the minute sweep
  replaying it for ever without ever saying so -- the same bound, and the
  same reason for it, as the extraction attempts on `game_reviews`. An
  operator clears the rows that gave up with `mix oskol.puzzles.sync
  --reset`.

  The GIN index is the partial one from `IndexSeatedRooms` without its
  predicate: that one covers only rooms a player can resume, and every game
  a puzzle comes from is over. A **guest's** practice session is "the
  mistakes on the seats this cookie holds", which is that containment test
  against finished rooms, and it is the only query that needs it.
  """

  def up do
    alter table(:puzzle_sources) do
      add(:owner_user_id, references(:users, type: :uuid, on_delete: :nilify_all))
      # Tries spent getting this row into a deck. Charged as it is read for
      # a sync, so a crash mid-write cannot refund it.
      add(:deck_attempts, :integer, null: false, default: 0)
      # Why the last try failed; what an operator looks for, and what
      # `--reset` selects on.
      add(:deck_error, :string)
    end

    # Every source already written: the same statement the two live paths
    # run, over all of them at once.
    execute("""
    UPDATE puzzle_sources s
    SET owner_user_id = (p ->> 'user_id')::uuid
    FROM games g, LATERAL jsonb_array_elements(oskol_players_jsonb(g.players)) p
    WHERE g.id = s.game_id
      AND p ->> 'id' = s.player_id
      AND p ->> 'user_id' IS NOT NULL
    """)

    # The sweep's whole question, as one index: owed, and to whom.
    create(
      index(:puzzle_sources, [:owner_user_id],
        where: "owner_user_id IS NOT NULL AND deck_synced_at IS NULL",
        name: :puzzle_sources_owed_deck
      )
    )

    create(
      index(:games, ["oskol_players_jsonb(players) jsonb_path_ops"],
        using: :gin,
        name: :games_players_gin
      )
    )
  end

  def down do
    drop(index(:games, [], name: :games_players_gin))
    drop(index(:puzzle_sources, [], name: :puzzle_sources_owed_deck))

    alter table(:puzzle_sources) do
      remove(:owner_user_id)
      remove(:deck_attempts)
      remove(:deck_error)
    end
  end
end
