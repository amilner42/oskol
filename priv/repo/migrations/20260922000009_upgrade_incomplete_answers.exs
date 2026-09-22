defmodule Oskol.Repo.Migrations.UpgradeIncompleteAnswers do
  use Ecto.Migration

  @moduledoc """
  What the backfill needs to reconcile a puzzle written from an old answer
  (the `puzzles-backfill` ticket).

  A stored answer is never rewritten -- a shared link must not change its
  mind -- with one audited exception, made here: an *incomplete* answer
  (a checker answer without every legal result, a cube answer without the
  chances it was judged on; both what an engine answer from before
  `all_results` gave) is replaced by a complete answer to the identical
  question. The question is the key, so it is the same puzzle; the
  complete answer is a superset of the old one (the same top five and the
  same equities, plus every other legal play); and nothing anyone was
  shown changes -- an attempt that was "unknown" becomes gradable, which
  is a gain and not a change of mind. `answer_upgraded_at` says it
  happened, so it can be audited and counted. A complete answer is never
  touched again.

  `complete` is Gleam's word on the answer (`oskol/puzzles.complete`),
  written beside it so the one write that may replace an answer decides
  on a column and never looks inside the JSON. Every row already stored is
  classified once here, the one place a migration may read an answer.
  """

  def up do
    alter table(:puzzles) do
      add(:complete, :boolean, null: false, default: false)
      add(:answer_upgraded_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE puzzles
       SET complete = CASE
             WHEN answer ->> 'kind' = 'move' THEN COALESCE((answer ->> 'complete')::boolean, false)
             WHEN answer ->> 'kind' = 'cube' THEN jsonb_typeof(answer -> 'probs') = 'object'
             ELSE false
           END
    """)
  end

  def down do
    alter table(:puzzles) do
      remove(:complete)
      remove(:answer_upgraded_at)
    end
  end
end
