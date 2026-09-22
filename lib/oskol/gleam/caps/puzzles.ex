defmodule Oskol.Gleam.Caps.Puzzles do
  @moduledoc """
  Real IO for src/oskol/caps/puzzles.gleam. Keep constructor tags and field
  order in lockstep:

      PuzzlesCaps(unextracted, store, failed, get, mine, game_sources,
      put_attempt, attempt, settle_attempt, cached_tree, keep_tree)
      NewPuzzle(key, ids, kind, question_json, answer_json, evaluated_by_json)
      NewSource(key, game_number, turn, kind, seat, player_id, played,
      equity_lost, grade, skipped_reason)
      Stored(id, kind, question_json, answer_json)
      Source(id, puzzle_id, kind, game_id, game_number, turn, seat,
      player_id, played, equity_lost, grade, date, question_json)
      SourceRoom(source, slug, seats)
      Attempt(id, puzzle_id, user_id, key, verdict, outcome, scheduled,
      review_id, schedule_json, fresh)

  A question, an answer and an evaluator cross as JSON text: Gleam wrote
  them and Gleam reads them back, so nothing here looks inside one.

  `store` never raises. Extraction is a bonus on top of a review that has
  already been stored, so a failure is logged and the game left unmarked
  for the sweep to try again within its budget.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Puzzles
  alias Oskol.Puzzles.TreeCache

  def build do
    {:puzzles_caps, &Puzzles.unextracted/1, &store/4, &failed/3, &get/1, &mine/3, &game_sources/2,
     &put_attempt/5, &attempt/2, &settle_attempt/5, &cached_tree/1, &keep_tree/2}
  end

  defp get(id) do
    opt(Puzzles.get(id), fn row ->
      {:stored, row.id, row.kind, Jason.encode!(row.question), Jason.encode!(row.answer)}
    end)
  end

  defp mine(puzzle_id, guest_id, user_id) do
    Enum.map(Puzzles.mine(puzzle_id, guest_id, user_id), fn {source, slug, players} ->
      {:source_room, source(source, nil), slug,
       Enum.map(players, fn p ->
         {p["id"] || "", p["name"] || "", p["guest_id"] || "", p["user_id"] || ""}
       end)}
    end)
  end

  defp game_sources(game_id, game_number) do
    Enum.map(Puzzles.game_sources(game_id, game_number), fn {source, question} ->
      source(source, question)
    end)
  end

  # A source, with its puzzle's question where the caller asked for it. A
  # date is a day, not a moment: the memory line says "12 Sep", never a
  # time, so that is all that crosses.
  defp source(s, question) do
    {:source, s.id, s.puzzle_id || "", s.kind, s.game_id, s.game_number, s.turn, s.seat,
     s.player_id || "", s.played || "", s.equity_lost || 0.0, s.grade || "",
     s.inserted_at |> DateTime.to_date() |> Date.to_iso8601(),
     if(question, do: Jason.encode!(question), else: "")}
  end

  defp put_attempt(puzzle_id, user_id, key, answer, verdict) do
    {freshness, row} =
      Puzzles.put_attempt(puzzle_id, user_id, key, Jason.decode!(answer), verdict)

    attempt_row(row, freshness == :fresh)
  end

  defp attempt(puzzle_id, key) do
    opt(Puzzles.attempt(puzzle_id, key), &attempt_row(&1, false))
  end

  defp attempt_row(row, fresh) do
    {:attempt, row.id, row.puzzle_id, row.user_id, row.idempotency_key, row.verdict || "",
     opt(row.outcome), row.scheduled, opt(row.review_id),
     if(row.schedule, do: Jason.encode!(row.schedule), else: ""), fresh}
  end

  defp settle_attempt(id, scheduled, review_id, outcome, schedule) do
    :ok =
      Puzzles.settle_attempt(id, scheduled, unopt(review_id), unopt(outcome), decoded(schedule))

    nil
  end

  defp decoded(""), do: nil
  defp decoded(json), do: Jason.decode!(json)

  defp cached_tree(id), do: opt(TreeCache.get(id))

  defp keep_tree(id, text) do
    :ok = TreeCache.put(id, text)
    nil
  end

  defp store(game_id, game_number, puzzles, sources) do
    case Puzzles.store(
           game_id,
           game_number,
           Enum.map(puzzles, &puzzle/1),
           Enum.map(sources, &source/1)
         ) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp failed(game_id, game_number, reason) do
    :ok = Puzzles.failed(game_id, game_number, reason)
    nil
  end

  defp puzzle({:new_puzzle, key, ids, kind, question, answer, evaluated_by}) do
    %{
      key: key,
      ids: ids,
      kind: kind,
      question: Jason.decode!(question),
      answer: Jason.decode!(answer),
      evaluated_by: Jason.decode!(evaluated_by)
    }
  end

  defp source(
         {:new_source, key, game_number, turn, kind, seat, player_id, played, equity_lost, grade,
          skipped_reason}
       ) do
    %{
      key: unopt(key),
      game_number: game_number,
      turn: turn,
      kind: kind,
      seat: seat,
      player_id: player_id,
      played: played,
      equity_lost: equity_lost,
      grade: grade,
      skipped_reason: unopt(skipped_reason)
    }
  end
end
