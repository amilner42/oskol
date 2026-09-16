defmodule Oskol.Repo.Migrations.DropSeatTokens do
  use Ecto.Migration

  # Seats used to carry a secret token, which was what opened them. A seat is
  # now held by the guest that took it (`games.players` has carried the guest
  # id all along), so the tokens are dead weight: nothing mints them, nothing
  # reads them, and a room rebuilt from its row ignores the key.
  #
  # They are still secrets, though, and a secret nothing uses should not sit
  # in a table waiting to be leaked, so this strips the key from every seat.
  # A room that is live in a running server keeps its in-memory seats either
  # way, and its next write puts the token-less shape back on disk.
  #
  # `players` is a Postgres array of jsonb, one element per seat, and its
  # order is the seat order: WITH ORDINALITY is what keeps player one first.
  def up do
    execute("""
    UPDATE games
       SET players = (
             SELECT array_agg(seat - 'token'::text ORDER BY ord)
               FROM unnest(players) WITH ORDINALITY AS t(seat, ord)
           )
     WHERE EXISTS (
             SELECT 1
               FROM unnest(players) AS seat
              WHERE jsonb_exists(seat, 'token')
           )
    """)
  end

  # There is nothing to put back: the tokens are gone and nothing mints them.
  def down, do: :ok
end
