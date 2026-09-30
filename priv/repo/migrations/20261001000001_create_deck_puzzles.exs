defmodule Oskol.Repo.Migrations.CreateDeckPuzzles do
  use Ecto.Migration

  @moduledoc """
  Universal decks (the `bg-opening-decks` ticket): practice decks that are
  not made of anybody's mistakes and are offered to everyone -- the 15
  opening rolls, the 315 replies to them, and whatever comes next.

  A row says a puzzle is in a deck and where it comes. The puzzle itself is
  an ordinary `puzzles` row, deduplicated by its question like any other,
  so an opening that is also somebody's mistake is one puzzle in two
  places. What a deck is called and how it is practised is Gleam's
  (`src/oskol/practice/decks.gleam`); a player's progress on it is retain's,
  in a scope of its own.

  Written only by the operator's build (`mix oskol.decks.build`), which asks
  the engine; nothing a player does writes here. Empty after this migration:
  a deck with no rows is simply not offered yet.
  """

  def change do
    create table(:deck_puzzles, primary_key: false) do
      # The deck's id in the Gleam registry: "openings", "opening_replies".
      add(:deck, :string, primary_key: true)
      add(:puzzle_id, references(:puzzles, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      # The order the deck introduces its positions in, smallest first.
      add(:position, :integer, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:deck_puzzles, [:deck, :position]))
  end
end
