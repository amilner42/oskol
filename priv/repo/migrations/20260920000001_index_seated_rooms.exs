defmodule Oskol.Repo.Migrations.IndexSeatedRooms do
  use Ecto.Migration

  # `players` is a jsonb[] because a room's seats are separate JSON values.
  # PostgreSQL marks its generic `to_jsonb(anyelement)` helper stable, so it
  # cannot appear in an index expression even though jsonb[] -> jsonb has no
  # configuration-dependent result. Narrow that fact to this input type, then
  # use the same expression in Persistence.seated_rooms/2.
  #
  # The partial index only contains rooms a player can resume. Build it
  # concurrently: this migration runs against the live games table, where a
  # table-locking index build would interrupt joins and moves.
  @disable_ddl_transaction true
  # Ecto's migration lock is a transaction on a second connection. PostgreSQL
  # makes CREATE INDEX CONCURRENTLY wait for that transaction's virtual xid,
  # so the documented concurrent-DDL shape must disable both. Deploys run one
  # release migration runner; this migration is otherwise retry-safe below.
  @disable_migration_lock true

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION oskol_players_jsonb(jsonb[])
    RETURNS jsonb
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    STRICT
    RETURN to_jsonb($1)
    """)

    execute("""
    -- Retrying an interrupted concurrent build can leave its invalid shell
    -- behind. The migration row is not recorded until the whole `up` has
    -- succeeded, so clear that exact shell before building again.
    DROP INDEX CONCURRENTLY IF EXISTS games_unfinished_players_gin
    """)

    execute("""
    CREATE INDEX CONCURRENTLY games_unfinished_players_gin
    ON games
    USING gin (oskol_players_jsonb(players) jsonb_path_ops)
    WHERE status IN ('waiting', 'playing')
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY games_unfinished_players_gin")
    execute("DROP FUNCTION oskol_players_jsonb(jsonb[])")
  end
end
