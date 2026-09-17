defmodule Oskol.Repo.Migrations.StoreReviewsAndRecords do
  use Ecto.Migration

  # A finished game never changes, so its record and its rendered analysis
  # are written once, at the two moments the work is already being done, and
  # read back with a SELECT. Additive: nothing here rewrites what is there,
  # and a room stored before this fills its rows in on the first read.
  def change do
    alter table(:game_reviews) do
      # The rendered analysis of this one game, exactly as the page reads it
      # (`oskol/reviews/report.to_json`). Null until the engine's answer
      # lands and renders.
      add :report, :map
      # How many turns this game had -- what the engine was asked about.
      # Zero is a game that ended before anyone completed a turn.
      add :turns, :integer
    end

    create table(:game_records, primary_key: false) do
      add :game_id, references(:games, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false

      # 1 for a room's first game, counting up through a match.
      add :game_number, :integer, primary_key: true, null: false
      # That game's record entries, as GET /record lists them.
      add :entries, :map, null: false
      # A row is only ever written for a game that is over; the column says
      # so out loud, and guards a row from being rewritten.
      add :finished, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end
  end
end
