defmodule OskolWeb.Api.DecksController do
  @moduledoc """
  The universal decks, as JSON:

      GET  /papi/decks            every deck on offer, with the caller's standing
      GET  /papi/decks/:id        a session: what to play next (?all=1: PRACTICE ANYWAY,
                                  &from=<n>: its rotation past the first n)
      POST /papi/decks/:id/join   {tz} -- add the deck, then the session
      POST /papi/decks/:id/more   KEEP GOING: the set's pace again, then the session

  Every decision -- which decks are offered, an account's queue against
  everybody else's walk through the deck, what adding one writes -- belongs
  to `oskol/handlers/decks` and `oskol/practice/decks`. This turns a conn
  into a context and a session and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def index(conn, _params) do
    json_resp(conn, 200, :oskol@handlers@decks.list_json(ctx(), session(conn)))
  end

  def show(conn, %{"id" => id} = params) do
    send_json(
      conn,
      :oskol@handlers@decks.session_from_json(
        ctx(),
        session(conn),
        id,
        params["all"] == "1",
        count(params["from"])
      )
    )
  end

  def more(conn, %{"id" => id}) do
    send_json(conn, :oskol@handlers@decks.more_json(ctx(), session(conn), id))
  end

  def join(conn, %{"id" => id} = params) do
    tz =
      case Map.get(params, "tz") do
        tz when is_binary(tz) -> tz
        _ -> ""
      end

    send_json(conn, :oskol@handlers@decks.join_json(ctx(), session(conn), id, tz))
  end

  # A count from the query string; anything that is not one is 0.
  defp count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 0
    end
  end

  defp count(_), do: 0

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
