defmodule Oskol.Repo.Migrations.CreatePuzzles do
  use Ecto.Migration

  @moduledoc """
  The tables a puzzle lives in (the `puzzles-store` ticket).

  A puzzle is public and deduplicated: `puzzles` is the question and the
  answer, keyed by the sha256 of the canonical question, so the same
  position asked the same way is one row whoever reached it. Whose mistake
  it was is `puzzle_sources`, one row per qualifying decision of a game --
  including the turns that were skipped, which carry a reason and no
  puzzle so a later repair can find them.

  Additive, and nothing is backfilled: games graded before this have no
  pre-move boards in any row, and the operator task that replays them is
  its own ticket.

  `puzzle_attempts`, `puzzle_shares` and `puzzle_images` are created here
  and written by later tickets (the API, the story link, the board
  picture); they are the same milestone and one migration is cheaper than
  four.
  """

  def change do
    create table(:puzzles, primary_key: false) do
      # Eight characters of the room-code alphabet, read off the key's own
      # digest, so extracting the same game twice asks for the same row.
      add(:id, :string, primary_key: true)
      # sha256 of the canonical question, in hex. What makes two the same.
      add(:key, :string, null: false)
      # move | double | take
      add(:kind, :string, null: false)
      # Mover-relative: board, dice (move only), cube, away scores,
      # Crawford, Jacoby. Decided in src/oskol/puzzles.gleam.
      add(:question, :map, null: false)
      # The engine's answer, as it was when this puzzle was written. Never
      # rewritten: a shared link must not change its mind.
      add(:answer, :map, null: false)
      # Which engine, at which search depth.
      add(:evaluated_by, :map)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:puzzles, [:key]))
    create(index(:puzzles, [:kind]))

    create table(:puzzle_sources) do
      # Null for a decision that qualified but was not asked: the checker
      # play after a taken double, until the engine grades those on the
      # cube they were really played on.
      add(:puzzle_id, references(:puzzles, type: :string, on_delete: :delete_all))

      add(:game_id, references(:games, type: :string, on_delete: :delete_all), null: false)

      add(:game_number, :integer, null: false)
      # Which turn of that game, counting from 1 as the review numbers them.
      add(:turn, :integer, null: false)
      add(:kind, :string, null: false)
      # The seat that made the decision: the mover for a move or a double,
      # the responder for a take.
      add(:seat, :integer, null: false)
      add(:player_id, :string)
      # The move played in notation, or the cube action taken.
      add(:played, :text)
      add(:equity_lost, :float)
      # The engine's band: doubtful, bad, very_bad.
      add(:grade, :string)
      # Why no puzzle was written for this decision, when none was.
      add(:skipped_reason, :string)
      # When the owning account's deck was given this one (the deck ticket).
      add(:deck_synced_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # One row per decision: what makes a rerun of the extraction write
    # nothing.
    create(unique_index(:puzzle_sources, [:game_id, :game_number, :turn, :kind]))
    create(index(:puzzle_sources, [:puzzle_id]))
    # The deck sweep's question: sources not yet in anybody's deck.
    create(index(:puzzle_sources, [:deck_synced_at], where: "deck_synced_at IS NULL"))

    create table(:puzzle_attempts) do
      add(:puzzle_id, references(:puzzles, type: :string, on_delete: :delete_all), null: false)

      add(:user_id, references(:users, type: :uuid, on_delete: :delete_all))
      # The client's own key for this answer: a retried POST is the same
      # attempt, and only the first one may move the schedule.
      add(:idempotency_key, :string, null: false)
      # The move played or the band chosen.
      add(:answer, :map)
      # pass | hold | fail | unknown
      add(:verdict, :string)
      # The player's override of the grade, when they gave one.
      add(:outcome, :string)
      # This attempt consumed the item's review opportunity.
      add(:scheduled, :boolean, null: false, default: false)
      add(:at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:puzzle_attempts, [:puzzle_id, :user_id, :idempotency_key]))
    create(index(:puzzle_attempts, [:user_id]))

    create table(:puzzle_shares, primary_key: false) do
      add(:token, :string, primary_key: true)
      add(:puzzle_id, references(:puzzles, type: :string, on_delete: :delete_all), null: false)

      # The one source this story is about, so the replay link, the date and
      # the move all name the same event.
      add(:source_id, references(:puzzle_sources, on_delete: :delete_all), null: false)

      # Who minted it: the guest id or the account id that held the source's
      # seat at that moment.
      add(:shared_by, :string, null: false)
      # The name shown on the share, frozen here. A guest id rotates, a seat
      # can be taken over and an account can be renamed; the person who
      # consented to be named must not change underneath the link.
      add(:shared_name, :string)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(index(:puzzle_shares, [:puzzle_id]))

    create table(:puzzle_images, primary_key: false) do
      add(:puzzle_id, references(:puzzles, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:png, :binary)
      add(:rendered_at, :utc_datetime_usec)
      # Render attempts spent, bounded like an analysis's.
      add(:attempts, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
