defmodule Mix.Tasks.Oskol.Puzzles.RepairPostTake do
  @shortdoc "Delete puzzles asked on the cube from before a take, for the sweep to redo (dry run unless --write)"
  @moduledoc """
  The repair for `bg-post-take-cube` (`Oskol.Puzzles.PostTakeRepair`).

      mix oskol.puzzles.repair_post_take           # dry run: one line per puzzle
      mix oskol.puzzles.repair_post_take --write   # delete them and reopen their games

  A dry run reads and writes nothing. A second run finds nothing to do.
  The queue is off for the run; the application's own sweep extracts the
  reopened games afterwards.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [write: :boolean])
    write? = Keyword.get(opts, :write, false)

    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    write?
    |> Oskol.Puzzles.PostTakeRepair.run()
    |> Oskol.Puzzles.PostTakeRepair.describe(write?)
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end
end
