defmodule Oskol.Repo.Migrations.MarkPuzzlesExtracted do
  use Ecto.Migration

  @moduledoc """
  The durable marker that says the sweep is done with a graded game.

  Set in the same transaction as the puzzle and source rows, so a crash
  between the engine's answer landing and the extraction leaves the game
  visibly unextracted rather than silently puzzle-less. The review queue's
  minute sweep asks the partial index below for exactly that, and extracts
  from the answer already stored -- never from the engine.

  `puzzles_attempts` bounds it: a game whose extraction keeps failing is
  charged before each try, and the try that spends the last one sets the
  marker with `puzzles_error` beside it. So a bug cannot make the sweep
  replay one room every minute for ever, and an operator has the reason in
  a column. Three attempts, as an analysis gets.

  **Every review already stored is marked here, and none of them has
  puzzles.** Without this the boot sweep would find the whole of production
  owed and backfill it at deploy: unvalidated, ahead of the reviews of
  games actually being played, and out of answers written before
  `all_results` existed, so every puzzle it made would be incomplete.
  Backfilling old rooms is its own ticket (`puzzles-backfill`) and will
  re-ask the engine. It identifies an old row by its stored response -- a
  turn whose `move` carries no `results` was graded before the flag -- and
  never by this marker, which from here on means only "the sweep has no
  more work here".
  """

  def up do
    alter table(:game_reviews) do
      add(:puzzles_extracted_at, :utc_datetime_usec)
      add(:puzzles_attempts, :integer, null: false, default: 0)
      add(:puzzles_error, :text)
    end

    # Settle every review that exists today. From here the marker is only
    # ever set by an extraction that ran, or by one that gave up.
    execute("""
    UPDATE game_reviews
       SET puzzles_extracted_at = inserted_at,
           puzzles_error = 'graded before puzzles existed; see puzzles-backfill'
     WHERE status IN ('done', 'failed')
    """)

    # The sweep's whole question, and it touches neither body column.
    create(
      index(:game_reviews, [:game_id],
        name: :game_reviews_puzzles_owed_index,
        where:
          "status = 'done' AND response IS NOT NULL AND puzzles_extracted_at IS NULL AND puzzles_attempts < 3"
      )
    )
  end

  def down do
    drop(index(:game_reviews, [:game_id], name: :game_reviews_puzzles_owed_index))

    alter table(:game_reviews) do
      remove(:puzzles_extracted_at)
      remove(:puzzles_attempts)
      remove(:puzzles_error)
    end
  end
end
