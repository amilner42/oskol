defmodule Oskol.Puzzles.BackfillGuardsTest do
  @moduledoc """
  What the backfill refuses to write: an answer it cannot trust is
  quarantined, counted and not asked again; an engine failure is charged to
  the game and skipped without stopping the run; a dry run asks nothing and
  writes nothing at all. The upgrade these guard is in
  `puzzles_backfill_test.exs`.
  """
  use Oskol.BackfillCase

  test "an answer that cannot be trusted is quarantined, counted, and not asked again" do
    {game_id, _turns} = old_room(33)
    before = review_row(game_id)
    # The engine still answers the old way.
    engine(self(), fn request -> {:ok, request_answer(request, complete: false)} end)

    totals = run(write: true, room: game_id)

    assert [_one] = engine_calls()
    assert totals.quarantined == %{"results_missing" => 1}
    assert totals.reasked == 0
    row = review_row(game_id)
    assert row.response == before.response
    assert row.report == before.report
    assert row.attempts == 3
    assert row.error =~ "quarantined: results_missing"
    assert row.puzzles_extracted_at == before.puzzles_extracted_at
    assert sources_of(game_id) == []

    # Spent: the next run says so and spends no engine time.
    again = run(write: true, room: game_id)
    assert engine_calls() == []
    assert again.spent == 1
    assert again.games == 0

    # Until an operator lets it try again, with the engine fixed.
    engine(self(), &fresh/1)
    reset = run(write: true, room: game_id, reset: true)
    assert [_one] = engine_calls()
    assert reset.reset == 1
    assert reset.reasked == 1
    refute old?(review_row(game_id))
  end

  test "an engine failure is charged, skipped, and the run goes on" do
    {failing, _} = old_room(34)
    {fine, _} = old_room(35)
    # Rooms come oldest first: the first request fails, the second lands.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    engine(self(), fn request ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, 503}
        _ -> fresh(request)
      end
    end)

    totals = run(write: true)

    assert length(engine_calls()) == 2
    assert totals.failed == 1
    assert totals.reasked == 1
    failed_row = review_row(failing)
    assert old?(failed_row)
    assert failed_row.attempts == 2
    assert failed_row.error =~ "HTTP 503"
    assert failed_row.status == "done"
    refute old?(review_row(fine))
  end

  test "a dry run asks nothing and writes nothing" do
    {game_id, _turns} = old_room(36)
    before = review_row(game_id)
    engine(self(), fn _ -> flunk("a dry run never asks the engine") end)

    totals = run(room: game_id)

    assert engine_calls() == []
    assert totals.games == 1
    assert totals.reasked == 0
    assert review_row(game_id) == before
    assert sources_of(game_id) == []
  end
end
