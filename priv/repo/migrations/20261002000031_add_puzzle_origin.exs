defmodule Oskol.Repo.Migrations.AddPuzzleOrigin do
  use Ecto.Migration

  @moduledoc """
  Where a puzzle row was first written from (the `analysis-ask-api`
  ticket): `game` (a graded game's mistake), `set` (a built set's
  position), `analysis` (a position somebody set up and asked the engine
  about), `replay` (a replay step somebody shared). Set once, by whichever
  write got the key first, and never changed.

  It exists so that TRY ONE and the status page, which hand a stranger a
  puzzle at random, take only `game` and `set`: a board somebody set up is
  a public row (every puzzle is), but nobody meant it for a stranger.

  Every row before this one came from a game or from a set's build; the
  ones a set holds are `set`.
  """

  def up do
    alter table(:puzzles) do
      add(:origin, :text, null: false, default: "game")
    end

    create(index(:puzzles, [:origin]))

    execute("""
    UPDATE puzzles SET origin = 'set'
    WHERE id IN (SELECT puzzle_id FROM deck_puzzles)
    """)
  end

  def down do
    drop(index(:puzzles, [:origin]))

    alter table(:puzzles) do
      remove(:origin)
    end
  end
end
