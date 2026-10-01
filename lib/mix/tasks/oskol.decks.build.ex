defmodule Mix.Tasks.Oskol.Decks.Build do
  @shortdoc "Build the universal decks from the engine (dry run unless --write)"
  @moduledoc """
  Ask the analysis engine about every position the universal decks are
  missing -- the 15 openings, then the 315 replies to them -- and write the
  answers as puzzles in their decks.

      mix oskol.decks.build            # dry run: what would be asked, no engine
      mix oskol.decks.build --write    # ask and write

  Safe to run again: a position already in its deck is never asked twice.
  The replies are asked against the openings as stored, so a first run
  builds the openings and then their replies. In production the same run is
  `Oskol.Release.build_decks/1`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [write: :boolean])
    write? = Keyword.get(opts, :write, false)

    # Nothing here needs the review queue, and its boot sweep would ask the
    # engine beside this run.
    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    reports = Oskol.Decks.build(write?)
    Mix.shell().info(Oskol.Decks.describe(reports))
    unless write?, do: Mix.shell().info("dry run (pass --write)")
  end
end
