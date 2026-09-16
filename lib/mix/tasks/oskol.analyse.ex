defmodule Mix.Tasks.Oskol.Analyse do
  @shortdoc "Analyse finished games that have no analysis yet"

  @moduledoc """
  Catches up games that finished before there was an analysis to run, or
  whose analysis was lost.

      mix oskol.analyse            # say what is owed, change nothing
      mix oskol.analyse --write    # run them, one room at a time

  A game is analysed once, when it ends: the room casts to
  `Oskol.Reviews.Queue` and that is the only path that spends engine time.
  Reading an analysis never starts one, however many people read it, because
  a room code is six characters and a reader is anyone. This task is the
  operator's way in, and is how a game from before the pipeline gets its
  one analysis.

  Needs the engine reachable (`ANALYSIS_URL`), which on a laptop means
  `fly proxy 18082:80 oskol-analysis.flycast -a oskol-analysis`.
  """

  use Mix.Task

  import Ecto.Query

  alias Oskol.Repo
  alias Oskol.Reviews

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    write? = "--write" in args

    owed = owed()

    if owed == [] do
      Mix.shell().info("Every finished game has an analysis.")
    else
      Mix.shell().info("#{length(owed)} room(s) with an analysis owed: #{Enum.join(owed, ", ")}")

      if write? do
        Enum.each(owed, fn game_id ->
          Mix.shell().info("analysing #{game_id}…")
          Reviews.Queue.run(game_id)
        end)

        Mix.shell().info("done")
      else
        Mix.shell().info("Nothing written. Pass --write to run them.")
      end
    end
  end

  # Finished rooms with no `done` review to their name.
  defp owed do
    analysed =
      from(r in "game_reviews", where: r.status == "done", select: r.game_id, distinct: true)
      |> Repo.all()
      |> MapSet.new()

    from(g in "games", where: g.status == "finished", select: g.code)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(analysed, &1))
  end
end
