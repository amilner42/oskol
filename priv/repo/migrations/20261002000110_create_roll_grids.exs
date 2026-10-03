defmodule Oskol.Repo.Migrations.CreateRollGrids do
  use Ecto.Migration

  @moduledoc """
  A cache of per-roll grids (the `rolls-server` ticket).

  How each of the 21 distinct rolls fares from one board is a pure function of
  the question asked -- the board, the cube, the match score and the depth --
  so it is keyed on the sha256 of the engine request body, exactly as
  `turn_grades` is keyed on a one-turn review's. A grid is found by the
  question it answers and by nothing else, and a row is never rewritten.

  The analysis board asks for one on a press and the replay asks for a turn
  the engine was never asked about (the grids of every review graded from now
  on ride in the review itself). Either costs about 0.2 s of engine time, so
  this table is a politeness rather than a necessity: losing the whole of it
  costs 0.2 s a grid.

  Rows are swept after a week, with the turn grades' keep-days.
  """

  def change do
    create table(:roll_grids, primary_key: false) do
      # sha256, in hex, of the `POST /backgammon/rolls` body Gleam built.
      add(:grid_key, :string, primary_key: true)
      # The engine's answer for that board, verbatim: {level, equity, rows}.
      add(:answer, :map, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # The sweep's index: a week-old row is found without reading the table.
    create(index(:roll_grids, [:inserted_at]))
  end
end
