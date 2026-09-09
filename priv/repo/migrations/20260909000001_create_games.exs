defmodule Oskol.Repo.Migrations.CreateGames do
  use Ecto.Migration

  def change do
    create table(:games, primary_key: false) do
      # The public game code ("483920", "483920-r1" after a rematch).
      add :id, :string, primary_key: true
      add :slug, :string, null: false
      # %{format, selections, clock, seed} — the creator's setup.
      add :config, :map, null: false, default: %{}
      add :seed, :bigint
      # Seat order: [%{id, name, token}]. Tokens round-trip so a player's
      # ?t= URL still opens their seat after rehydration.
      add :players, {:array, :map}, null: false, default: []
      # waiting | playing | finished (abandoned is reserved; pruning deletes).
      add :status, :string, null: false, default: "waiting"
      add :winners, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:games, [:status, :updated_at])

    create table(:game_actions, primary_key: false) do
      add :game_id, references(:games, type: :string, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :index, :integer, primary_key: true, null: false
      # "action" (a player's or the engine's auto action via apply) or
      # "expire" (a clock ran out and the room resolved it).
      add :kind, :string, null: false
      add :player_id, :string
      add :payload, :map
      # Milliseconds since the instance started: replaying the log at these
      # offsets reproduces every clock deduction and timeout exactly.
      add :at_ms, :bigint, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end
end
