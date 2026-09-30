defmodule Oskol.Repo.Migrations.CreateTurnGrades do
  use Ecto.Migration

  @moduledoc """
  A warm cache of turns already graded (the `bg-analysis-per-turn` ticket).

  A backgammon turn is graded the moment it is committed, while the game goes
  on, so the report is ready when the game ends instead of a minute after it.
  The row is a cache and nothing else: `Oskol.Reviews.Grader` writes it and
  the end-of-game review job is the only thing that reads it. Nothing a
  player can reach touches this table.

  `turn_key` is the sha256 of the exact request body the engine was asked, so
  a grade is found by the question it answers and by nothing else: a turn can
  only ever be served a grade of itself, and grading the same turn twice
  (a duplicate cast) writes the same row.

  Rows are spent as soon as the game's own answer is written, and the job
  drops them then. What is left is a room nobody finished, which the Grader's
  sweep drops after a week. Nothing here is durable state: losing the whole
  table costs one batch review at the end of a game, which is what happened
  before this existed.
  """

  def change do
    create table(:turn_grades, primary_key: false) do
      add(:game_id, :string, primary_key: true)
      add(:game_number, :integer, primary_key: true)
      # sha256, in hex, of the one-turn review request. What makes two the
      # same question.
      add(:turn_key, :string, primary_key: true)
      # The engine's reply for that one turn, verbatim: what the assembled
      # review hands back as the turn's own answer.
      add(:response, :map, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The sweep's index: a week-old row is found without reading the table.
    create(index(:turn_grades, [:inserted_at]))
  end
end
