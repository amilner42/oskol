defmodule Oskol.Puzzles.BackfillTest do
  @moduledoc """
  The backfill's upgrade path: a game graded before `all_results` is asked
  again at its stored levels, its answer and page replaced and its puzzles
  written complete, the puzzles written from the old answer upgraded while a
  complete one is left alone -- and, run a second time, nothing left to do.
  What the run declines to write is in `puzzles_backfill_guards_test.exs`.
  What is old, what is trusted and what is written in what order are decided
  and tested in Gleam (test/oskol/backfill_test.gleam).
  """
  use Oskol.BackfillCase

  test "an old game is re-asked at its levels, re-rendered and extracted complete" do
    {game_id, turns} = old_room(31)
    engine(self(), &fresh/1)
    before = review_row(game_id)
    assert old?(before)

    totals = run(write: true, room: game_id)

    assert [request] = engine_calls()
    assert request["all_results"] == true
    assert request["move_level"] == "4ply"
    assert request["cube_level"] == "4ply"
    assert length(request["turns"]) == length(turns)

    row = review_row(game_id)
    refute old?(row)
    assert row.status == "done"
    assert row.attempts == 2
    assert is_nil(row.error)
    assert row.report != before.report
    assert row.puzzles_extracted_at
    assert is_nil(row.puzzles_error)

    mistakes =
      Enum.count(turns, fn {:turn, _, _, {:position, board, _, _, _, _, _}, _, dice, played, _, _,
                            _, _} ->
        dice != :none and played != {:some, board}
      end)

    assert length(sources_of(game_id)) == mistakes
    assert mistakes > 0
    puzzles = puzzles_of(game_id)
    assert puzzles != []
    assert Enum.all?(puzzles, & &1.complete)
    assert Enum.all?(puzzles, &(&1.answer["complete"] == true))
    assert Enum.all?(puzzles, &(length(&1.answer["outcomes"]) == @n_legal))
    assert Enum.all?(puzzles, &is_nil(&1.answer_upgraded_at))

    assert totals.games == 1
    assert totals.reasked == 1
    assert totals.puzzles == length(puzzles)
    assert totals.sources == mistakes
    assert totals.engine_ms == 2500
    assert totals.quarantined == %{}
    assert totals.failed == 0
  end

  test "puzzles written from the old answer are upgraded; a complete one is left alone" do
    {game_id, _turns} = old_room(32)
    # The sweep's own extraction of the old answer, as production did
    # before the migration marked every old row.
    from(r in Reviews.Review, where: r.game_id == ^game_id)
    |> Repo.update_all(set: [puzzles_extracted_at: nil, puzzles_error: nil])

    :ok = Oskol.Reviews.Queue.run(game_id)
    old = puzzles_of(game_id)
    assert old != []
    assert Enum.all?(old, &(&1.complete == false))

    # One of them, complete already by some other game's answer: it must
    # not be touched.
    [settled | _] = old
    sentinel = %{settled.answer | "outcomes" => [%{"board" => [], "equity_lost" => 0.0}]}

    from(p in Puzzles.Puzzle, where: p.id == ^settled.id)
    |> Repo.update_all(set: [complete: true, answer: sentinel])

    engine(self(), &fresh/1)
    totals = run(write: true, room: game_id)

    assert [_one] = engine_calls()
    after_run = puzzles_of(game_id)
    assert length(after_run) == length(old)
    upgraded = Enum.reject(after_run, &(&1.id == settled.id))
    assert Enum.all?(upgraded, & &1.complete)
    assert Enum.all?(upgraded, & &1.answer_upgraded_at)
    assert Enum.all?(upgraded, &(&1.answer["complete"] == true))
    kept = Enum.find(after_run, &(&1.id == settled.id))
    assert kept.answer == sentinel
    assert is_nil(kept.answer_upgraded_at)

    assert totals.upgraded == length(upgraded)
    assert totals.puzzles == 0
    assert totals.sources == 0
    # The same rows, still one source per mistake.
    assert length(sources_of(game_id)) == length(old)
  end

  test "a second run finds nothing to do and writes nothing" do
    {game_id, _turns} = old_room(37)
    engine(self(), &fresh/1)
    assert %{reasked: 1} = run(write: true, room: game_id)
    assert [_one] = engine_calls()
    settled = review_row(game_id)
    puzzles = puzzles_of(game_id)

    again = run(write: true, room: game_id)

    assert engine_calls() == []
    assert again.games == 0
    assert again.reasked == 0
    assert again.puzzles == 0
    assert again.upgraded == 0
    assert review_row(game_id) == settled
    assert puzzles_of(game_id) == puzzles
  end

  test "a game already graded with every result is not a candidate" do
    %{game_id: game_id} = started(38, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, 38, 3000)
    Persister.flush()
    turns = turns_of(game_id)
    new = answer(turns, complete: true)

    :ok =
      Reviews.save(game_id, 1, "done", 1, new, nil, rendered(game_id, new, turns), length(turns))

    engine(self(), fn _ -> flunk("nothing to ask") end)

    totals = run(write: true, room: game_id)

    assert engine_calls() == []
    assert totals.games == 0
    assert totals.rooms == 1
  end
end
