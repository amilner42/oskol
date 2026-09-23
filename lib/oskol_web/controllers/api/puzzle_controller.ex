defmodule OskolWeb.Api.PuzzleController do
  @moduledoc """
  Puzzles as JSON, for the puzzle page:

      GET  /papi/puzzles/:id                         the question and every
                                                     legal way to play it
      GET  /papi/puzzles/:id/tree?node=              one level of a tree too
                                                     big to send whole
      POST /papi/puzzles/:id/attempts                grade it and reveal it
      POST /papi/puzzles/:id/attempts/:key/outcome   the player's override
      GET  /papi/puzzles/:id/mine                    the memory line
      POST /papi/puzzles/:id/shares                  a share-with-my-story link
      GET  /papi/games/:slug/rooms/:id/puzzles?game= one game's mistakes

  Every decision -- what a puzzle says, whether an answer is right, what it
  does to a deck, who may see a memory line -- belongs to
  `oskol/handlers/puzzles`, which renders the whole envelope. This module
  turns a conn into a context, a session and a clock, and writes the bytes.

  The clock crosses explicitly rather than as a capability: whether a card
  is due is arithmetic, and a handler that is handed the time is one a test
  can put at any moment it likes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def show(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@puzzles.puzzle_json(ctx(), id))
  end

  def tree(conn, %{"id" => id} = params) do
    send_json(
      conn,
      :oskol@handlers@puzzles.tree_node_json(ctx(), id, param(params, "node"))
    )
  end

  def attempt(conn, %{"id" => id} = params) do
    send_json(
      conn,
      :oskol@handlers@puzzles.attempt_json(
        ctx(),
        session(conn),
        id,
        {:attempted, moves(params), band(params), param(params, "key")},
        # The `?s=` the page was opened with, if any: the story it opens
        # rides on this answer and nowhere earlier.
        param(params, "s"),
        System.system_time(:millisecond)
      )
    )
  end

  def share(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@shares.mint_json(ctx(), session(conn), id))
  end

  def outcome(conn, %{"id" => id, "key" => key} = params) do
    send_json(
      conn,
      :oskol@handlers@puzzles.outcome_json(
        ctx(),
        session(conn),
        id,
        key,
        param(params, "outcome")
      )
    )
  end

  def mine(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@puzzles.mine_json(ctx(), session(conn), id))
  end

  def game(conn, %{"slug" => slug, "id" => game_id} = params) do
    send_json(
      conn,
      :oskol@handlers@puzzles.game_puzzles_json(
        ctx(),
        session(conn),
        slug,
        game_id,
        to_int(Map.get(params, "game"))
      )
    )
  end

  # A path through the tree, as the page walked it. Anything malformed comes
  # through as nothing at that step and the handler refuses the whole path:
  # a half-read move is not a move.
  defp moves(params) do
    case Map.get(params, "moves") do
      list when is_list(list) -> Enum.map(list, &move/1)
      _ -> []
    end
  end

  defp move(%{} = m), do: {text(m["from"]), text(m["to"]), to_int(m["die"])}
  defp move(_), do: {"", "", 0}

  defp band(params) do
    case Map.get(params, "band") do
      n when is_integer(n) -> {:some, n}
      n when is_binary(n) -> opt_int(n)
      _ -> :none
    end
  end

  defp opt_int(text) do
    case Integer.parse(text) do
      {value, ""} -> {:some, value}
      _ -> :none
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp to_int(_), do: 0

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
