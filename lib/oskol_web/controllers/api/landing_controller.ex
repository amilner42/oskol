defmodule OskolWeb.Api.LandingController do
  @moduledoc """
  The landing pages as JSON, for the Elm client:

      GET  /papi/library                   the library grid
      GET  /papi/games/:slug               one game's start page
      POST /papi/games/:slug                create a room and take the first seat
      GET  /papi/games/:slug/rooms/:id     what that invite link offers
      POST /papi/games/:slug/rooms/:id     join by name, or take a seat back
      GET  /papi/games/:slug/rooms/:id/reviews  post-game reviews, per game
      POST /papi/games/:slug/rooms/:id/reviews/retry  try a failed review again (a seat)
      GET  /papi/games/:slug/rooms/:id/record?t=   the game's whole record, for a seat
      GET  /papi/codes/:code               which game answers to a code
      GET  /papi/me/prefs                  this visitor's display preferences
      POST /papi/me/prefs                  keep one of them

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
        param(params, "clock"),
        selections(params)
      )
    )
  end

  def room(conn, %{"id" => game_id}) do
    send_json(conn, {:ok, :oskol@handlers@landing.room_json(ctx(), game_id)})
  end

  # Post-game reviews of a room's games. A game with none yet is queued by
  # the handler and answers pending.
  def reviews(conn, %{"slug" => slug, "id" => game_id}) do
    send_json(conn, :oskol@handlers@reviews.reviews_json(ctx(), slug, game_id))
  end

  # A failed review, queued again at a seat's request.
  def retry_review(conn, %{"slug" => slug, "id" => game_id} = params) do
    number =
      case Map.get(params, "game_number") do
        n when is_integer(n) -> n
        _ -> 0
      end

    send_json(
      conn,
      :oskol@handlers@reviews.retry_json(ctx(), slug, game_id, param(params, "t"), number)
    )
  end

  # One door for both ways into a seat: a name takes a free one, a player id
  # takes back one whose player went away.
  def seat(conn, %{"slug" => slug, "id" => game_id, "player_id" => player_id})
      when is_binary(player_id) do
    send_json(conn, :oskol@handlers@landing.claim_json(ctx(), slug, game_id, player_id))
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

  # The seat token rides as `t`, as on the game page's own URL: it is what
  # opens the record, exactly as it opens the seat.
  def record(conn, %{"slug" => slug, "id" => game_id} = params) do
    send_json(
      conn,
      :oskol@handlers@record.record_json(ctx(), slug, game_id, param(params, "t"))
    )
  end

  def code(conn, %{"code" => code}) do
    send_json(conn, :oskol@handlers@landing.code_json(ctx(), code))
  end

  # No player process to seat: a room made from here holds a seat with no
  # live connection, exactly as a rehydrated one does until its player comes
  # back with the link this request hands out.
  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

  # A missing or non-string field is an empty one; the handler decides what
  # that means.
  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  # The creator's setting choices, as the #(setting_id, choice_id) pairs the
  # handler takes. Anything that is not a string pair is not a choice.
  defp selections(params) do
    case Map.get(params, "selections") do
      %{} = selections ->
        for {setting, choice} <- selections,
            is_binary(setting) and is_binary(choice),
            do: {setting, choice}

      _ ->
        []
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
