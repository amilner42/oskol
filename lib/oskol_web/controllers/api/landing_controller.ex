defmodule OskolWeb.Api.LandingController do
  @moduledoc """
  The landing pages as JSON, for the Elm client:

      GET  /papi/library        the library grid
      GET  /papi/games/:slug    one game's start page
      POST /papi/games/:slug    create a room and take the first seat

  Every decision — what a page carries, whether a name will do, what a
  refusal says — belongs to the Gleam handler `oskol/handlers/landing`,
  which renders the whole envelope. This module turns a conn into a context
  and a session, and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def library(conn, _params) do
    send_json(conn, {:ok, :oskol@handlers@landing.library_json(ctx(conn), session(conn))})
  end

  def show(conn, %{"slug" => slug}) do
    send_json(conn, :oskol@handlers@landing.game_json(ctx(conn), session(conn), slug))
  end

  def create(conn, %{"slug" => slug} = params) do
    send_json(
      conn,
      :oskol@handlers@landing.create_json(
        ctx(conn),
        session(conn),
        slug,
        param(params, "format"),
        param(params, "name")
      )
    )
  end

  # No player process to seat: an API-created room holds a seat with no live
  # connection, exactly as a rehydrated one does until its player comes back.
  defp ctx(_conn), do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

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
