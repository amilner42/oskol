defmodule OskolWeb.Api.LandingController do
  @moduledoc """
  The landing pages as JSON, for the Elm client:

      GET  /papi/library                   the library grid
      GET  /papi/games/:slug               one game's start page
      POST /papi/games/:slug                create a room and take the first seat
      GET  /papi/games/:slug/rooms/:id     what that invite link offers
      POST /papi/games/:slug/rooms/:id     join by name, or take a seat back
      GET  /papi/games/:slug/rooms/:id/reviews  the index of a room's reviews (open)
      GET  /papi/games/:slug/rooms/:id/reviews/:game_number  one game's analysis (open)
      POST /papi/games/:slug/rooms/:id/reviews/retry  try a failed review again (a seat)
      GET  /papi/games/:slug/rooms/:id/record  the game's whole record, for anyone
                                              with the room
      GET  /papi/games/:slug/rooms/:id/ratings  each seat's PR so far in this match
      GET  /papi/codes/:code               which game answers to a code
      GET  /papi/me/prefs                  this visitor's display preferences
      POST /papi/me/prefs                  keep one of them
      POST /papi/me/games/:id/abandon      end one room from the rejoin list

  Every decision — what a page carries, whether a name will do, what a
  refusal says, what an invite is worth — belongs to the Gleam handlers in
  `oskol/handlers/landing`, which render the whole envelope. This module
  turns a conn into a context and a session, and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def library(conn, _params) do
    send_json(conn, {:ok, :oskol@handlers@landing.library_json(ctx(), session(conn))})
  end

  def show(conn, %{"slug" => slug}) do
    send_json(conn, :oskol@handlers@landing.game_json(ctx(), session(conn), slug))
  end

  def create(conn, %{"slug" => slug} = params) do
    send_json(
      conn,
      :oskol@handlers@landing.create_json(
        ctx(),
        session(conn),
        slug,
        param(params, "format"),
        param(params, "name"),
        param(params, "clock")
      )
    )
  end

  def room(conn, %{"slug" => slug, "id" => game_id}) do
    send_json(
      conn,
      {:ok, :oskol@handlers@landing.room_json(ctx(), session(conn), slug, game_id)}
    )
  end

  # The index of a room's post-game reviews: which games it has and where
  # each one's analysis stands. A few hundred bytes, read out of rows.
  def reviews(conn, %{"slug" => slug, "id" => game_id}) do
    send_json(conn, :oskol@handlers@reviews.reviews_json(ctx(), session(conn), slug, game_id))
  end

  # One game's analysis: the stored answer, verbatim. Reading it never puts
  # the engine to work.
  def review(conn, %{"slug" => slug, "id" => game_id, "game_number" => number}) do
    send_json(
      conn,
      :oskol@handlers@reviews.review_json(ctx(), session(conn), slug, game_id, to_int(number))
    )
  end

  # A failed review, queued again at a seat's request.
  def retry_review(conn, %{"slug" => slug, "id" => game_id} = params) do
    number = to_int(Map.get(params, "game_number"))

    send_json(
      conn,
      :oskol@handlers@reviews.retry_json(ctx(), session(conn), slug, game_id, number)
    )
  end

  # One door for both ways into a seat: a name takes a free one, a player id
  # takes back one whose player went away.
  def seat(conn, %{"slug" => slug, "id" => game_id, "player_id" => player_id})
      when is_binary(player_id) do
    send_json(
      conn,
      :oskol@handlers@landing.claim_json(ctx(), session(conn), slug, game_id, player_id)
    )
  end

  def seat(conn, %{"slug" => slug, "id" => game_id} = params) do
    send_json(
      conn,
      :oskol@handlers@landing.join_json(
        ctx(),
        session(conn),
        slug,
        game_id,
        param(params, "name")
      )
    )
  end

  # Display preferences (a board's colours): the visitor's own taste, kept
  # against the silent guest. Never a room's business, so it hangs off the
  # caller and not off a game.
  def prefs(conn, _params) do
    send_json(conn, {:ok, :oskol@handlers@landing.prefs_json(ctx(), session(conn))})
  end

  def save_pref(conn, params) do
    send_json(
      conn,
      :oskol@handlers@landing.save_pref_json(
        ctx(),
        session(conn),
        param(params, "key"),
        param(params, "value")
      )
    )
  end

  # The games this browser can pick back up: the unfinished rooms its guest
  # holds a seat in, read from their rows. Nothing here wakes a room.
  def my_games(conn, _params) do
    send_json(conn, {:ok, :oskol@handlers@landing.my_games_json(ctx(), session(conn))})
  end

  def abandon(conn, %{"id" => game_id}) do
    send_json(conn, :oskol@handlers@landing.abandon_json(ctx(), session(conn), game_id))
  end

  # The record opens on the room: it is every committed turn, which both
  # players already saw. The caller's guest only decides which seat the
  # board faces to begin with.
  def record(conn, %{"slug" => slug, "id" => game_id}) do
    send_json(
      conn,
      :oskol@handlers@record.record_json(ctx(), session(conn), slug, game_id)
    )
  end

  # What the two people at this room have played like before. No token: a
  # PR is a fact about a player their opponent is sitting across from
  # anyway, and it says nothing about the game on the board.
  def ratings(conn, %{"slug" => slug, "id" => game_id}) do
    send_json(conn, :oskol@handlers@ratings.ratings_json(ctx(), slug, game_id))
  end

  def code(conn, %{"code" => code}) do
    send_json(conn, :oskol@handlers@landing.code_json(ctx(), code))
  end

  # No player process to seat: a room made from here holds a seat with no
  # live connection, exactly as a rehydrated one does until its player comes
  # back with the link this request hands out.
  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

  # A game number, from the path or the body. Anything that is not one is
  # zero, which names no game; the handler decides what that means.
  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  # A missing or non-string field is an empty one; the handler decides what
  # that means.
  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp send_json(conn, {:ok, body}), do: json_resp(conn, 200, body)

  defp send_json(conn, {:error, error}) do
    {status, body} = :oskol@core@envelope.error(error)
    json_resp(conn, status, body)
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
