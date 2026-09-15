defmodule Oskol.Repo.Migrations.AddGuestPrefs do
  use Ecto.Migration

  def change do
    # A generic bag of display preferences kept against the silent guest:
    # today the backgammon board theme, tomorrow whatever else is the
    # player's own taste rather than the room's setup. Never anything the
    # opponent or the engine sees, so it lives here and not in `games`.
    #
    # Additive and defaulted, so an old row and an old release both read
    # fine while this migrates on boot.
    alter table(:guests) do
      add :prefs, :map, null: false, default: %{}
    end
  end
end
