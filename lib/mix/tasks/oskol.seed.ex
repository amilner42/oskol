defmodule Mix.Tasks.Oskol.Seed do
  @shortdoc "Seed local backgammon rooms at codes 000001.. in positions worth testing"
  @moduledoc """
  Writes a room per scenario in `Oskol.Dev.Seeds` at a fixed six-digit code
  (000001, 000002, ...), P1 and P2 seated, P1 always the one to act, and
  prints each seat's link. Open P1's link to test; P2's in another tab if
  the scenario needs the other side to answer.

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
      Mix.shell().info("#{row.code}  #{row.what}  (seed #{row.seed}, #{row.steps} steps)")
      Mix.shell().info("        P1  #{row.links["P1"]}")
      Mix.shell().info("        P2  #{row.links["P2"]}")
    end
  end
end
