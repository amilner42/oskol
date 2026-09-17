defmodule Oskol.Repo.Migrations.MirrorGameState do
  use Ecto.Migration

  # What is going on in a game lived only in its process and, once that had
  # idled out, only in the action log. Anything that wants to list or watch
  # active games had to wake every room it looked at. The room now writes a
  # small public snapshot beside the row on every step (`gamekit/host.
  # summary_json`): who may act, whose clock runs, the outcome, each
  # player's public counters. A row from before this is null until its room
  # next wakes, which writes it.
  #
  # The first question that needs it -- which unfinished rooms does this
  # guest hold a seat in -- runs a jsonb containment over `players` after
  # the status index has narrowed the rows to the unfinished ones, which
  # the pruner keeps to a few days' worth. No index of its own: `players`
  # is jsonb[], and Postgres will not index `to_jsonb(players)` (it is
  # marked stable, not immutable). Should that scan ever matter, an
  # immutable wrapper function is the way to give it one.
  def change do
    alter table(:games) do
      add :state, :map
    end
  end
end
