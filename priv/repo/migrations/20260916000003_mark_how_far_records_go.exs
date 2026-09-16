defmodule Oskol.Repo.Migrations.MarkHowFarRecordsGo do
  @moduledoc """
  How far a room's stored records go, as a position in its action log.

  Records are written per finished game. Without a mark, a room whose rows
  were written when only its first game was over looks complete forever --
  it has rows, so nothing goes back to look -- and its record silently
  stops at game one. The mark says which log the rows were made from, so a
  log that has grown since is settled again and a log that has not is never
  replayed.
  """
  use Ecto.Migration

  def change do
    alter table(:games) do
      add :records_through, :integer
    end
  end
end
