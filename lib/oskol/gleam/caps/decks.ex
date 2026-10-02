defmodule Oskol.Gleam.Caps.Decks do
  @moduledoc """
  Real IO for src/oskol/caps/decks.gleam. Keep constructor tags and field
  order in lockstep:

      DeckCaps(practice, members, size, store, own, create, rename, delete,
               add_member, remove_member)
      Member(puzzle_id, position, kind, question_json)
      Stored(puzzles, upgraded, members)
      OwnDeck(id, user_id, name, new_per_day)
      Refusal: NameTaken | IdTaken (the atoms name_taken, id_taken)
      Added(added, position)
      NewPuzzle is caps/puzzles.gleam's, read as that cap reads it.

  `practice` hands back the practice caps over a retain scope
  (`Oskol.Gleam.Caps.Practice.build/1`): a universal deck is scheduled on
  exactly the code an account's mistakes are, one scope along.
  """

  def build do
    {:deck_caps, &Oskol.Gleam.Caps.Practice.build/1, &members/1, &Oskol.Puzzles.deck_size/1,
     &store/2, &own/1, &create/4, &rename/2, &delete/1, &add_member/2,
     &Oskol.OwnDecks.remove_member/2}
  end

  defp own(user_id), do: Enum.map(Oskol.OwnDecks.own(user_id), &own_deck/1)

  defp create(user_id, id, name, new_per_day) do
    case Oskol.OwnDecks.create(user_id, id, name, new_per_day) do
      {:ok, deck} -> {:ok, own_deck(deck)}
      {:error, refusal} -> {:error, refusal}
    end
  end

  defp rename(id, name) do
    case Oskol.OwnDecks.rename(id, name) do
      {:ok, deck} -> {:ok, own_deck(deck)}
      {:error, refusal} -> {:error, refusal}
    end
  end

  defp delete(id) do
    :ok = Oskol.OwnDecks.delete(id)
    nil
  end

  defp add_member(deck, puzzle_id) do
    {added, position} = Oskol.OwnDecks.add_member(deck, puzzle_id)
    {:added, added, position}
  end

  defp own_deck(%Oskol.OwnDecks.Deck{} = deck) do
    {:own_deck, deck.id, deck.user_id, deck.name, deck.new_per_day}
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
