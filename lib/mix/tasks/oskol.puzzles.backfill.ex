defmodule Mix.Tasks.Oskol.Puzzles.Backfill do
  @shortdoc "Re-ask the engine about games graded before all_results (dry run unless --write)"
  @moduledoc """
  The puzzles backfill: every game whose stored answer predates the engine
  sending every legal result is asked again, its answer and page replaced,
  its puzzles written complete (old incomplete ones upgraded, post-take
  plays graded on the right cube), and every owed deck synced.

      mix oskol.puzzles.backfill                 # dry run: one line per old game
      mix oskol.puzzles.backfill --write         # re-ask them, oldest first
      mix oskol.puzzles.backfill --room 821900   # one room
      mix oskol.puzzles.backfill --limit 5       # stop after five games
      mix oskol.puzzles.backfill --write --reset # first let games whose tries are spent be asked again

  Needs the engine reachable (`ANALYSIS_URL`), which on a laptop means
  `fly proxy 18082:80 oskol-analysis.flycast -a oskol-analysis`. This is
  the one sanctioned re-ask: reading never spends engine time.

  A dry run replays each room (settling only what a read of its replay
  page would), reads its stored answers, asks the engine nothing and
  writes nothing of its own. A game the engine does not answer is charged one of its three
  tries and skipped; a fresh answer that cannot be trusted (a legal result
  missing, a candidate without its board, a cube verdict without its
  chances) is quarantined -- not stored, charged to the limit, named with
  its reason -- and the run goes on. A second run finds nothing to do.

  The queue is turned off before the application starts, so its minute
  sweep cannot extract a game this is in the middle of re-asking.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [write: :boolean, room: :string, limit: :integer, reset: :boolean]
      )

    # Before the application starts: otherwise the boot sweep runs beside
    # this and extracts a game whose answer is being replaced.
    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    Oskol.Puzzles.Backfill.run(
      write: Keyword.get(opts, :write, false),
      room: Keyword.get(opts, :room),
      limit: Keyword.get(opts, :limit),
      reset: Keyword.get(opts, :reset, false),
      say: &Mix.shell().info(&1)
    )
  end
end
