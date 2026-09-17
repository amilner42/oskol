defmodule Oskol.Repo.Migrations.AddAnalysisOwedAt do
  @moduledoc """
  Adds `games.analysis_owed_at` to a database that already ran
  `MarkAnalysesOwed` before that column was part of it.

  The earlier migration was edited after it had been applied in
  production, which Postgres has no way to notice: the version was
  recorded as run, so the new column never appeared, and code that reads
  it would fail. This adds it where it is missing and does nothing where
  the first migration already created it, so a fresh database and the one
  in production end up the same.

  The lesson, for the next time: a migration that has run anywhere is
  history. Change it by adding another one.
  """
  use Ecto.Migration

  def up do
    execute("ALTER TABLE games ADD COLUMN IF NOT EXISTS analysis_owed_at timestamp(6)")
  end

  def down do
    execute("ALTER TABLE games DROP COLUMN IF EXISTS analysis_owed_at")
  end
end
