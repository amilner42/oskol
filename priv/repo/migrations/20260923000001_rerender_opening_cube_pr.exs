defmodule Oskol.Repo.Migrations.RerenderOpeningCubePr do
  use Ecto.Migration

  # The rendered analysis carried each seat's PR as the engine totalled it,
  # and the engine counts a "no double" on the opening roll, where nobody
  # could have doubled. After Crawford that is a missed double charged to
  # whoever opens behind (in the 2024 UBC final it turned a game played at
  # 0.0 into 11.4). The report now leaves that verdict out of the totals as
  # well as the page. The engine's answer is stored verbatim beside the
  # report, so clearing the report is enough: the first read of each game
  # renders it afresh from `response`, as after RerenderCubeReports. Match
  # PRs read `response` directly and are right without this.
  def up do
    execute("UPDATE game_reviews SET report = NULL WHERE status = 'done' AND response IS NOT NULL")
  end

  def down, do: :ok
end
