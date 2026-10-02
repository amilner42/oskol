defmodule Mix.Tasks.Oskol.Puzzles.RefreshOwners do
  @shortdoc "Give mistakes the owner their seat has, then fill those decks (dry run unless --write)"
  @moduledoc """
  The repair for `puzzles-stale-owner`: every room whose seats name an
  account that its puzzle sources do not, put right.

      mix oskol.puzzles.refresh_owners           # dry run: one line per room and account
      mix oskol.puzzles.refresh_owners --write   # refresh the owners, then sync those decks

  A seat that reached an account by a signed-in claim, before that write
  refreshed the room's sources, left the mistakes on it owned by nobody;
  the deck finds a mistake by its owner, so that account's deck never got
  them. `--write` points the sources at the seat's account
  (`Oskol.Puzzles.refresh_owners/1`) and syncs each affected account's
  deck over those rooms (`Oskol.Practice.sync/2`). No engine is asked.

  A dry run reads and writes nothing. A second run finds nothing to do.

  The queue is turned off before the application starts, so the boot
  sweep does not run beside this and charge the same rows twice.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [write: :boolean])
    write? = Keyword.get(opts, :write, false)

    Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
    Mix.Task.run("app.start")

    write?
    |> Oskol.Practice.refresh_owners()
    |> Oskol.Practice.describe_refresh(write?)
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end
end
