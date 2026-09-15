defmodule Mix.Tasks.Oskol.PatchReadyUp do
  @shortdoc "Insert the READYs old backgammon match logs lack (dry run unless --write)"
  @moduledoc """
  Looks over every backgammon match or unlimited room in the database and,
  where its log goes from a game's end straight into the next game (as logs
  did before the between-games READY), shows the `ready` steps it would
  insert. See `Oskol.Game.ReadyUpPatch`.

      mix oskol.patch_ready_up           # dry run: one line per room
      mix oskol.patch_ready_up --write   # rewrite the logs that need it

  The boot-time migration `PatchReadyUpLogs` already does this once; the
  task is for looking, and for a database restored from before it.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [write: :boolean])
    write? = Keyword.get(opts, :write, false)
    Mix.Task.run("app.start")

    reports = Oskol.Game.ReadyUpPatch.run(write: write?)
    Enum.each(reports, &Mix.shell().info(Oskol.Game.ReadyUpPatch.describe(&1)))
    Mix.shell().info("#{length(reports)} rooms, #{if write?, do: "written", else: "dry run"}")
  end
end
