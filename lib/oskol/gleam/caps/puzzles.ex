defmodule Oskol.Gleam.Caps.Puzzles do
  @moduledoc """
  Real IO for src/oskol/caps/puzzles.gleam. Keep constructor tags and field
  order in lockstep:

      PuzzlesCaps(unextracted, store, failed)
      NewPuzzle(key, ids, kind, question_json, answer_json, evaluated_by_json)
      NewSource(key, game_number, turn, kind, seat, player_id, played,
      equity_lost, grade, skipped_reason)

  A question, an answer and an evaluator cross as JSON text: Gleam wrote
  them and Gleam reads them back, so nothing here looks inside one.

  `store` never raises. Extraction is a bonus on top of a review that has
  already been stored, so a failure is logged and the game left unmarked
  for the sweep to try again within its budget.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Puzzles

  def build do
    {:puzzles_caps, &Puzzles.unextracted/1, &store/4, &failed/3}
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
