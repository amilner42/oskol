defmodule Oskol.Repo.Migrations.PuzzleAttemptSchedule do
  use Ecto.Migration

  @moduledoc """
  What an attempt did to the deck, kept on the attempt itself (the
  `puzzles-api` ticket).

  Two columns, both for the same reason: an answer is given once and may be
  asked about twice.

    * `review_id` names the deck review this attempt wrote. The player's
      override after the reveal *replaces* that review rather than stacking
      on it, and a correction has to name the row it supersedes.
    * `schedule` is what the answer reported -- level before, level after,
      the next due date. A retried key has to come back with the same thing
      it came back with the first time, and by then the card has moved on,
      so working it out again would be a different answer.

  Additive; nothing is backfilled, because no attempt has been written yet.
  """

  def change do
    alter table(:puzzle_attempts) do
      add(:review_id, :bigint)
      add(:schedule, :map)
    end
  end
end
