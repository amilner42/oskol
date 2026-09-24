defmodule Mix.Tasks.Oskol.Puzzles.Reposition do
  @shortdoc "Put every card back in the queue worst-first (dry run unless --write)"
  @moduledoc """
  A one-off. New mistakes used to be introduced newest game first and
  nothing else; they are now introduced **worst first**, and the newest
  game first within a band (`oskol/practice/sync.position_of`). The rows
  already written still carry the old order, so a deck filled before the
  change would go on offering a dubious move from this morning ahead of a
  very bad one from last year.

      mix oskol.puzzles.reposition             # dry run: what would move
      mix oskol.puzzles.reposition --write     # move them
      mix oskol.puzzles.reposition --limit 5000  # more decks than the default

  Every position is recomputed from the `puzzle_sources` rows the card was
  made from, which is exactly what a fresh sync would write, so running it
  twice is a no-op: the second run has nothing to move. A dry run reads
  and writes nothing at all.

  Only the order **new** cards are introduced in changes. A card already
  in rotation keeps its level, its due date and its log; nothing about
  what anybody has learned is touched.

  The queue is turned off before the application starts, so its boot sweep
  does not write new cards beside this.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [write: :boolean, limit: :integer])

    write? = Keyword.get(opts, :write, false)
    limit = Keyword.get(opts, :limit, 500)

    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    totals = Oskol.Practice.reposition(limit, write?)

    Mix.shell().info(
      "#{totals.accounts} decks, #{totals.cards} mistakes read, #{totals.moved} " <>
        if(write?, do: "moved", else: "would move (dry run, pass --write)")
    )
  end
end
