defmodule Oskol.Repo.Migrations.CreateOwnDecks do
  use Ecto.Migration

  @moduledoc """
  A player's own sets (the `analysis-own-sets-api` ticket): a named
  collection an account makes and saves positions into, practiced exactly
  as the universal sets are.

  This row is only what a universal set's registry entry is in Gleam (its
  name, its pace) plus who owns it. Its positions are `deck_puzzles` rows
  under its id, as Openings' are, and its owner's ladder is the retain
  scope `"deck:" <> id`, as Openings' is, so nothing about practicing it is
  new.

  The id is eight characters of the room-code alphabet (upper case and
  digits), which is what keeps it apart from every universal set's id
  ("openings", "opening_replies") in `deck_puzzles.deck` and in a scope.

  A deleted set keeps its row (`deleted_at`), its membership and its
  ladder, like a suspended card; only the name is freed for another set.
  """

  def change do
    create table(:decks, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false)
      # 1..40 characters, trimmed (`oskol/handlers/own_decks.checked_name`).
      add(:name, :text, null: false)
      add(:new_per_day, :integer, null: false, default: 5)
      add(:deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:decks, [:user_id, :inserted_at]))

    create(
      unique_index(:decks, ["user_id", "lower(name)"],
        where: "deleted_at IS NULL",
        name: :decks_user_id_lower_name_index
      )
    )
  end
end
