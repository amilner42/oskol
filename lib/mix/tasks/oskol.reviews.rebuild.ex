defmodule Mix.Tasks.Oskol.Reviews.Rebuild do
  @shortdoc "Build again the reviews that came back empty (dry run unless --write)"
  @moduledoc """
  The games whose review says `done` with nothing in it, and putting them
  back in the queue.

      mix oskol.reviews.rebuild                 # dry run: one line per game
      mix oskol.reviews.rebuild --write         # queue them
      mix oskol.reviews.rebuild --room EGKR03   # one room
      mix oskol.reviews.rebuild --limit 200     # look further back

  Written for one bug: ending an unlimited session read as a second game
  ending, and the empty half of that overwrote the real answer
  (`bg-session-close-wiped-reviews`). The record rows were never touched,
  so every one of these can be built again from the log.

  **Run it after the fix is deployed.** Under the code that caused this the
  replay produces the same empty answer again, and the sweep would spend
  engine time to write the same nothing back.

  A game that really had nothing to grade reads exactly the same as a game
  this emptied, so both are queued; the first kind comes back empty and
  costs a moment of engine time. A sweep that tried to tell them apart
  would be a sweep that missed some.

  A dry run reads and writes nothing.

  The queue is turned off before the application starts, so the boot sweep
  does not run beside this one.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [write: :boolean, room: :string, limit: :integer])

    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    Oskol.Release.rebuild_reviews(
      dry_run: Keyword.get(opts, :write, false) == false,
      room: Keyword.get(opts, :room),
      limit: Keyword.get(opts, :limit, 100),
      say: &Mix.shell().info/1
    )
  end
end
