defmodule Oskol.Repo.Migrations.IndexSeatedRooms do
  use Ecto.Migration

  # `players` is a jsonb[] because a room's seats are separate JSON values.
  # PostgreSQL marks its generic `to_jsonb(anyelement)` helper stable, so it
  # cannot appear in an index expression even though jsonb[] -> jsonb has no
  # configuration-dependent result. Narrow that fact to this input type, then
  # use the same expression in Persistence.seated_rooms/2.
  #
  # The partial index only contains rooms a player can resume. This ticket is
  # intentionally landing while the production table is still tiny, so keep
  # Ecto's transaction and migration lock rather than using CREATE INDEX
  # CONCURRENTLY and allowing two boot-time migrators to race.

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
    CREATE INDEX games_unfinished_players_gin
    ON games
    USING gin (oskol_players_jsonb(players) jsonb_path_ops)
    WHERE status IN ('waiting', 'playing')
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS games_unfinished_players_gin")
    execute("DROP FUNCTION IF EXISTS oskol_players_jsonb(jsonb[])")
  end
end
