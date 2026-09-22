defmodule Oskol.Repo.Migrations.AddPuzzleImageError do
  use Ecto.Migration

  @moduledoc """
  Why a puzzle's picture could not be drawn (the `puzzles-share-image`
  ticket).

  `puzzle_images.attempts` already bounds the tries; `error` says what the
  last one died of, so a row that has given up can be found and read by an
  operator rather than inferred from a count. The same pair as
  `puzzles_attempts` / `puzzles_error` on `game_reviews` and
  `deck_attempts` / `deck_error` on `puzzle_sources`, for the same reason:
  a render the minute sweep cannot make work must stop coming back, and
  must say so.

  The partial index is the sweep's question -- pictures still owed -- so
  it never scans the rows that are done.
  """

  def change do
    alter table(:puzzle_images) do
      add(:error, :text)
    end

    create(index(:puzzle_images, [:attempts], where: "png IS NULL"))
  end
end
