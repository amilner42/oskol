defmodule Oskol.Gleam.Caps.Puzzles do
  @moduledoc """
  Real IO for src/oskol/caps/puzzles.gleam. Keep constructor tags and field
  order in lockstep:

      PuzzlesCaps(unextracted, store, failed, owned_sources, mark_synced,
      sync_failed, deck_pending, guest_sources)
      NewPuzzle(key, ids, kind, question_json, answer_json, evaluated_by_json,
      complete)
      Written(puzzles, upgraded, sources)
      NewSource(key, game_number, turn, kind, seat, player_id, played,
      equity_lost, grade, skipped_reason)
      DeckSource(source_id, puzzle_id, game_id, game_number, kind, turn,
      question_json, ended_ms, seat)
      Pending(user_id, game_ids, sources)

  A question, an answer and an evaluator cross as JSON text: Gleam wrote
  them and Gleam reads them back, so nothing here looks inside one.

  `store` never raises. Extraction is a bonus on top of a review that has
  already been stored, so a failure is logged and the game left unmarked
  for the sweep to try again within its budget.
  """

  import Oskol.Gleam.Interop

  require Logger

  alias Oskol.Puzzles

  def build do
    {:puzzles_caps, &Puzzles.unextracted/1, &store/4, &failed/3, &owned_sources/2, &mark_synced/1,
     &sync_failed/2, &deck_pending/2, &guest_sources/1}
  end

  # The deck's own capabilities degrade rather than raise, the way
  # `seated_rooms` does: they are asked from inside the review job's task
  # and from the sweep, and a database hiccup must not lose a review that
  # has already been stored or take a sweep down. Nothing is marked, so the
  # next sweep does exactly the work this one did not.
  defp owned_sources(user_id, game_ids) do
    quietly([], fn -> user_id |> Puzzles.owned_sources(game_ids) |> Enum.map(&deck_source/1) end)
  end

  defp mark_synced(ids) do
    quietly(nil, fn ->
      :ok = Puzzles.mark_synced(ids)
      nil
    end)
  end

  defp sync_failed(ids, reason) do
    quietly(nil, fn ->
      :ok = Puzzles.sync_failed(ids, reason)
      nil
    end)
  end

  defp deck_pending(game_ids, limit) do
    quietly([], fn ->
      for row <- Puzzles.deck_pending(game_ids, limit) do
        {:pending, row.user_id, row.game_ids, row.sources}
      end
    end)
  end

  defp guest_sources(guest_id) do
    quietly([], fn -> guest_id |> Puzzles.guest_sources() |> Enum.map(&deck_source/1) end)
  end

  defp quietly(fallback, fun) do
    fun.()
  rescue
    e ->
      Logger.error("deck capability failed: #{Exception.message(e)}")
      fallback
  end

  # A seat crosses as the Gleam seat rules read it, exactly as a `games`
  # row's seats do: the holder rule is Gleam's, and nothing here judges an
  # id. A stored question crosses as the JSON text Gleam wrote.
  defp deck_source(row) do
    {:deck_source, row.id, row.puzzle_id, row.game_id, row.game_number, row.kind, row.turn,
     Jason.encode!(row.question), DateTime.to_unix(row.ended_at, :millisecond),
     {:seat, row.player_id, opt(blank_to_nil(row.guest_id)), opt(blank_to_nil(row.user_id))}}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp store(game_id, game_number, puzzles, sources) do
    case Puzzles.store(
           game_id,
           game_number,
           Enum.map(puzzles, &puzzle/1),
           Enum.map(sources, &source/1)
         ) do
      {:ok, counts} -> {:ok, {:written, counts.puzzles, counts.upgraded, counts.sources}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp failed(game_id, game_number, reason) do
    :ok = Puzzles.failed(game_id, game_number, reason)
    nil
  end

  defp puzzle({:new_puzzle, key, ids, kind, question, answer, evaluated_by, complete}) do
    %{
      key: key,
      ids: ids,
      kind: kind,
      question: Jason.decode!(question),
      answer: Jason.decode!(answer),
      evaluated_by: Jason.decode!(evaluated_by),
      complete: complete
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
