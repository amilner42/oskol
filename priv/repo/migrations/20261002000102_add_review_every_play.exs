defmodule Oskol.Repo.Migrations.AddReviewEveryPlay do
  use Ecto.Migration

  @moduledoc """
  Whether a game's stored engine answer carries every legal play of its
  checker plays (`results`, what the engine has sent since `all_results`):
  the one thing the replay must know before it offers SHARE on a roll, since
  a share refuses an answer short of them (`handlers/positions`). Older
  answers predate it, and the replay points those rolls at OPEN IN ANALYSIS
  instead of offering a button that would fail.

  A generated column, so it is right for every row already stored and every
  row written from now on without anybody computing it, and it is read
  beside the rendered report (`Oskol.Reviews.report/2`) without touching
  the answer itself, which is hundreds of kilobytes.
  """

  def up do
    execute("""
    ALTER TABLE game_reviews ADD COLUMN every_play boolean
      GENERATED ALWAYS AS (coalesce(jsonb_path_exists(response, '$.turns[*].move.results'), false)) STORED
    """)
  end

  def down do
    execute("ALTER TABLE game_reviews DROP COLUMN every_play")
  end
end
