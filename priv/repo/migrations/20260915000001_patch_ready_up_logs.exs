defmodule Oskol.Repo.Migrations.PatchReadyUpLogs do
  use Ecto.Migration

  # A data migration: backgammon logs written before the between-games READY
  # get the readies the engine now waits for (see Oskol.Game.ReadyUpPatch).
  # Migrations run on boot before the supervision tree starts, so this runs
  # once, before any room can rehydrate from an unpatched log.
  #
  # Each room is rewritten in its own transaction, and only if its patched
  # log replays cleanly; so no DDL transaction and no migration lock around
  # the whole run. A room that cannot be patched is logged and left as it
  # was: this must never keep the app from booting.
  @disable_ddl_transaction true
  @disable_migration_lock true

  require Logger

  def up do
    for report <- Oskol.Game.ReadyUpPatch.run(write: true), report.result != :unchanged do
      Logger.warning("ready-up patch: " <> Oskol.Game.ReadyUpPatch.describe(report))
    end
  rescue
    e -> Logger.error("ready-up patch did not run: " <> Exception.message(e))
  end

  def down, do: :ok
end
