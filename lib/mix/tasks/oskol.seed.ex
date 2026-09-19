defmodule Mix.Tasks.Oskol.Seed do
  @shortdoc "Seed local backgammon rooms at codes 000001.. in positions worth testing"
  @moduledoc """
  Writes a room per scenario in `Oskol.Dev.Seeds` at a fixed six-character
  code (000001, 000002, ...), P1 and P2 seated, P1 always the one to act,
  and prints the room's invite link. Nobody's browser holds either seat, so
  the invite offers both: open it and take P1 to test, and take P2 from
  another browser (or a private window) if the scenario needs the other
  side to answer.

      mix oskol.seed

  Reseeding replaces the rows. A code that is already open in a running
  server keeps its old log until that room stops: restart the server after
  reseeding it, or seed from the server's own IEx with
  `Oskol.Dev.Seeds.run()`, which stops the live rooms first.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Logger.configure(level: :info)
    Mix.Task.run("app.start")

    for row <- Oskol.Dev.Seeds.run() do
      case Map.get(row, :heading) do
        nil -> :ok
        heading -> Mix.shell().info("\n#{heading}")
      end

      Mix.shell().info("#{row.code}  #{row.what}  (seed #{row.seed}, #{row.steps} steps)")
      Mix.shell().info("        invite  #{row.links["invite"]}")
      Mix.shell().info("        table   #{row.links["table"]}")
    end
  end
end
