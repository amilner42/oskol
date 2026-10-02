defmodule Oskol.Repo.Migrations.AddPuzzleReplay do
  use Ecto.Migration

  @moduledoc """
  The replay step a puzzle was shared from (the `analysis-share-from-replay`
  ticket): `{slug, id, game, step}`, the room and the line of its record the
  position was taken from, so the puzzle page can offer WATCH THE REPLAY.

  Written once, by the first share of a key, and never moved: a new row
  gets it with the row, and a row already stored (a game's own mistake, a
  set's position) gets it only when it has none. Null everywhere else,
  which is every row before this one.
  """

  def change do
    alter table(:puzzles) do
      add(:replay, :map)
    end
  end
end
