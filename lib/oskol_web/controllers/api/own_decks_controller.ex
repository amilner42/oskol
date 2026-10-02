defmodule OskolWeb.Api.OwnDecksController do
  @moduledoc """
  A player's own sets, as JSON:

      GET    /papi/decks/mine                      the caller's sets
      POST   /papi/decks/mine            {name}    make one
      PATCH  /papi/decks/:id             {name}    rename it
      DELETE /papi/decks/:id                       delete it
      GET    /papi/decks/:id/puzzles               it, and what is in it
      POST   /papi/decks/:id/puzzles     {puzzle_id}  put a position in
      DELETE /papi/decks/:id/puzzles/:puzzle_id    take one out

  Every decision -- whose a set is, what a name may be, what saving a
  position writes -- belongs to `oskol/handlers/own_decks`. This turns a
  conn into a context and a session and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def index(conn, _params) do
    json_resp(conn, 200, :oskol@handlers@own_decks.mine_json(ctx(), session(conn)))
  end

  def create(conn, params) do
    send_json(
      conn,
      :oskol@handlers@own_decks.create_json(ctx(), session(conn), text(params["name"]))
    )
  end

  def update(conn, %{"id" => id} = params) do
    send_json(
      conn,
      :oskol@handlers@own_decks.rename_json(ctx(), session(conn), id, text(params["name"]))
    )
  end

  def delete(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@own_decks.delete_json(ctx(), session(conn), id))
  end

  def members(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@own_decks.show_json(ctx(), session(conn), id))
  end

  def add(conn, %{"id" => id} = params) do
    send_json(
      conn,
      :oskol@handlers@own_decks.add_json(ctx(), session(conn), id, text(params["puzzle_id"]))
    )
  end

  def remove(conn, %{"id" => id, "puzzle_id" => puzzle_id}) do
    send_json(conn, :oskol@handlers@own_decks.remove_json(ctx(), session(conn), id, puzzle_id))
  end

  # A string from the body; anything else is "", which Gleam refuses in
  # its own words.
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""

  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

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
