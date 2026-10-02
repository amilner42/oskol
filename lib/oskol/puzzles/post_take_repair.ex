defmodule Oskol.Puzzles.PostTakeRepair do
  @moduledoc """
  The repair for `bg-post-take-cube`: puzzles written for a roll played
  after a taken double, asked with the cube from before the double.

  The engine grades such a roll on the doubled cube, which the opponent now
  holds; `extract` used to build the question off the position the turn
  began on, so the puzzle showed one cube and was answered on another. The
  extractor asks with the right cube now (`analysis.played_on`). This puts
  right what it wrote before:

    * every such source is dropped, and every puzzle left with no source is
      deleted -- its attempts, shares, picture and set rows go with it (the
      foreign keys cascade) and so do the practice cards on it
      (`Oskol.Gleam.Caps.Practice.forget/1`), progress and all;
    * each game it touched is reopened (`Oskol.Puzzles.reopen/2`), so the
      minute sweep extracts it again with today's code: the corrected
      puzzles, under new ids (a question is its key), and the deck sync
      gives each account its card back, fresh.

  A source is one of these when its turn's double was taken (the stored
  report says so) and its puzzle's cube is not the opponent's: after a take
  it always is. So a corrected puzzle is never selected and a second run
  finds nothing. A dry run reads and writes nothing. Run it only where the
  fixed extractor is deployed, or the sweep writes the same puzzles again.
  """
  import Ecto.Query

  alias Oskol.Puzzles.{Puzzle, Source}
  alias Oskol.Repo
  alias Oskol.Reviews.Review

  @doc "The sources asked with the cube from before a taken double."
  def find do
    from(s in Source,
      join: r in Review,
      on: r.game_id == s.game_id and r.game_number == s.game_number,
      join: p in Puzzle,
      on: p.id == s.puzzle_id,
      where:
        s.kind == "move" and
          fragment("?->'turns'->(? - 1)->>'double'", r.report, s.turn) == "take" and
          fragment("?->'cube'->>'owner'", p.question) != "opponent",
      order_by: [s.game_id, s.game_number, s.turn],
      select: %{
        source_id: s.id,
        puzzle_id: s.puzzle_id,
        game_id: s.game_id,
        game_number: s.game_number,
        turn: s.turn
      }
    )
    |> Repo.all()
  end

  @doc """
  Find them and, when `write?`, repair them in one transaction. Answers what
  was found and, for a write, what was removed.
  """
  def run(write?) do
    found = find()

    removed =
      if write? and found != [] do
        {:ok, removed} = Repo.transaction(fn -> repair(found) end)
        removed
      end

    %{found: found, removed: removed}
  end

  defp repair(found) do
    puzzle_ids = found |> Enum.map(& &1.puzzle_id) |> Enum.uniq()

    {sources, _} =
      from(s in Source, where: s.id in ^Enum.map(found, & &1.source_id))
      |> Repo.delete_all()

    # A puzzle another game also asks, on a turn that was no take, keeps
    # that source and stays.
    orphaned =
      from(p in Puzzle,
        as: :puzzle,
        where:
          p.id in ^puzzle_ids and
            not exists(from(s in Source, where: s.puzzle_id == parent_as(:puzzle).id)),
        select: p.id
      )
      |> Repo.all()

    cards = Oskol.Gleam.Caps.Practice.forget(orphaned)
    {puzzles, _} = from(p in Puzzle, where: p.id in ^orphaned) |> Repo.delete_all()

    games = found |> Enum.map(&{&1.game_id, &1.game_number}) |> Enum.uniq()
    Enum.each(games, fn {game_id, number} -> :ok = Oskol.Puzzles.reopen(game_id, number) end)

    %{sources: sources, puzzles: puzzles, cards: cards, games: length(games)}
  end

  @doc "What a run found and did, a line at a time."
  def describe(%{found: found, removed: removed}, write?) do
    lines =
      Enum.map(found, fn f ->
        "#{f.game_id} game #{f.game_number} turn #{f.turn}: puzzle #{f.puzzle_id}"
      end)

    summary =
      cond do
        found == [] ->
          "Nothing to repair."

        not write? ->
          "#{length(found)} puzzle sources asked on the cube from before a take. Dry run: nothing written."

        true ->
          "Removed #{removed.sources} sources, #{removed.puzzles} puzzles and #{removed.cards} practice cards; " <>
            "#{removed.games} games reopened for the sweep to extract again."
      end

    lines ++ [summary]
  end
end
