defmodule Oskol.Gleam.Caps.Decks do
  @moduledoc """
  Real IO for src/oskol/caps/decks.gleam. Keep constructor tags and field
  order in lockstep:

      DeckCaps(practice, members, size, store)
      Member(puzzle_id, position, kind, question_json)
      Stored(puzzles, upgraded, members)
      NewPuzzle is caps/puzzles.gleam's, read as that cap reads it.

  `practice` hands back the practice caps over a retain scope
  (`Oskol.Gleam.Caps.Practice.build/1`): a universal deck is scheduled on
  exactly the code an account's mistakes are, one scope along.
  """

  def build do
    {:deck_caps, &Oskol.Gleam.Caps.Practice.build/1, &members/1, &Oskol.Puzzles.deck_size/1,
     &store/2}
  end

  defp members(deck) do
    deck
    |> Oskol.Puzzles.deck_members()
    |> Enum.map(fn m ->
      {:member, m.puzzle_id, m.position, m.kind, Jason.encode!(m.question)}
    end)
  end

  defp store(deck, entries) do
    entries = Enum.map(entries, fn {puzzle, position} -> {new_puzzle(puzzle), position} end)

    case Oskol.Puzzles.store_deck(deck, entries) do
      {:ok, %{puzzles: puzzles, upgraded: upgraded, members: members}} ->
        {:ok, {:stored, puzzles, upgraded, members}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The same reading `Oskol.Gleam.Caps.Puzzles` makes of a puzzle to write.
  defp new_puzzle({:new_puzzle, key, ids, kind, question, answer, evaluated_by, complete}) do
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
end
