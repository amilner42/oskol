defmodule Oskol.Repo.Migrations.MarkAnalysesOwed do
  @moduledoc """
  A durable note that a room owes an analysis.

  A game is analysed once, when it ends: the room casts to a queue that
  lives in memory. If the machine restarts between the cast and the job --
  a deploy at the wrong second -- the job is gone, and since a read no
  longer queues engine work (that is what took production down), nothing
  would ever pick it up. The game would sit `pending` forever while its
  players watched a progress bar.

  So the intent is written down before the job runs, and cleared when the
  room owes nothing. A sweep at boot queues whatever is still marked.
  """
  use Ecto.Migration

  def change do
    alter table(:games) do
      add(:analysis_owed, :boolean, default: false, null: false)
      # When the note was last made. A job clears only a note it has seen:
      # a game that ends while the job is running makes a newer one, and
      # wiping that would lose exactly the work this exists to keep.
      add(:analysis_owed_at, :utc_datetime_usec)
    end

    create(
      index(:games, [:analysis_owed], where: "analysis_owed", name: :games_analysis_owed_index)
    )
  end
end
