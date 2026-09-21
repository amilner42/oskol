defmodule Oskol.Repo.Migrations.TrackRecordGeneration do
  use Ecto.Migration

  def change do
    alter table(:games) do
      # Null is a legacy room: its first backfill establishes the marker.
      # Later invalidation follows analysis_owed_at, not every staged move.
      add(:records_generation, :bigint)
    end
  end
end
