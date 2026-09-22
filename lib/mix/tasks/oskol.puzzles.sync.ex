defmodule Mix.Tasks.Oskol.Puzzles.Sync do
  @shortdoc "Put unsynced mistakes into their owners' decks (dry run unless --write)"
  @moduledoc """
  The deck sweep, by hand: the accounts whose mistakes are not in their deck
  yet, and what putting them there would do.

      mix oskol.puzzles.sync             # dry run: one line per account
      mix oskol.puzzles.sync --write     # sync them
      mix oskol.puzzles.sync --reset     # let the rows that gave up be tried again
      mix oskol.puzzles.sync --limit 500 # look at more accounts than a sweep does

  The same work the review queue's minute sweep does (`Oskol.Practice`), so
  this is for looking, for a backlog after a restore, and for an operator
  who wants it to happen now rather than within the minute.

  A dry run reads and writes nothing at all -- no card, no marker, and not
  one of the tries a row is allowed.

  `--reset` zeroes `deck_attempts` on every row that gave up
  (`deck_error` is set), which is what an operator runs once they have
  fixed whatever the error said. It pairs with `--write`.

  The queue is turned off before the application starts, so the boot sweep
  does not run beside this and charge the same rows twice.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [write: :boolean, reset: :boolean, limit: :integer])

    write? = Keyword.get(opts, :write, false)
    reset? = Keyword.get(opts, :reset, false)
    limit = Keyword.get(opts, :limit, Oskol.Practice.sweep_batch())

    # Before the application starts: otherwise its boot sweep runs beside
    # this one and both charge the same rows for the same try.
    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    if reset? do
      Mix.shell().info("#{Oskol.Practice.reset()} rows reopened")
    end

    pending = Oskol.Practice.pending(limit)

    Enum.each(pending, fn row ->
      Mix.shell().info("#{row.user_id}: #{row.sources} mistakes in #{length(row.game_ids)} games")
    end)

    if write? do
      totals = Oskol.Practice.sweep(limit)

      Mix.shell().info(
        "#{totals.accounts} decks filled, #{totals.added} new cards, #{totals.failed} refused"
      )
    else
      Mix.shell().info("#{length(pending)} accounts owed, dry run (pass --write)")
    end
  end
end
