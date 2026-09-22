defmodule Oskol.Repo.Migrations.MarkPuzzlesExtracted do
  use Ecto.Migration

  @moduledoc """
  The durable marker that says a graded game's puzzles have been written.

  Set in the same transaction as the puzzle and source rows, so a crash
  between the engine's answer landing and the extraction leaves the game
  visibly unextracted rather than silently puzzle-less. The review queue's
  minute sweep asks the partial index below for exactly that, and extracts
  from the answer already stored -- never from the engine.

  `puzzles_attempts` bounds it: a game whose extraction keeps failing is
  charged before each try, so a bug cannot make the sweep replay one room
  every minute for ever. Three, as an analysis gets.
  """

  def change do
    alter table(:game_reviews) do
      add(:puzzles_extracted_at, :utc_datetime_usec)
      add(:puzzles_attempts, :integer, null: false, default: 0)
    end

    # The sweep's whole question, and it touches neither body column.
    create(
      index(:game_reviews, [:game_id],
        name: :game_reviews_puzzles_owed_index,
        where:
          "status = 'done' AND response IS NOT NULL AND puzzles_extracted_at IS NULL AND puzzles_attempts < 3"
      )
    )
  end
end
