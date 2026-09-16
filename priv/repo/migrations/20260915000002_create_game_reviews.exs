defmodule Oskol.Repo.Migrations.CreateGameReviews do
  use Ecto.Migration

  # Additive: a new table and nothing else. Games finished before it existed
  # are reviewed lazily, on the first request for them, never here.
  def change do
    create table(:game_reviews, primary_key: false) do
      add :game_id, references(:games, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false

      # 1 for a room's first game, counting up through a match.
      add :game_number, :integer, primary_key: true, null: false
      # pending | done | failed
      add :status, :string, null: false
      # Engine calls made so far (a failure is retried at most twice).
      add :attempts, :integer, null: false, default: 0
      # The analysis engine's response, verbatim, when done.
      add :response, :map
      # Why the last call failed, for the logs and nothing else.
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
