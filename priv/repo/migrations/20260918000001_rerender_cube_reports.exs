defmodule Oskol.Repo.Migrations.RerenderCubeReports do
  use Ecto.Migration

  # A game's rendered analysis (`game_reviews.report`) is written once and
  # never rebuilt, because rebuilding it means replaying the room's log.
  # This one time it has to be: the report now carries the chances a cube
  # decision was judged on (the replay's cube tab reads them) and leaves out
  # the engine's "no double" verdict on turns where no double was possible
  # (the opening roll, the other side's cube). Both come from the engine's
  # answer, which is stored verbatim beside the report, so nothing asks the
  # engine again: clearing the report is enough, and the first read of each
  # game renders it afresh from `response` and writes it back, the same
  # self-healing path a room from before reports existed takes.
  def up do
    execute("UPDATE game_reviews SET report = NULL WHERE status = 'done' AND response IS NOT NULL")
  end

  # The old reports are gone, and the new ones render on read either way.
  def down, do: :ok
end
