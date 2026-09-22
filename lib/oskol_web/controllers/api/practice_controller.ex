defmodule OskolWeb.Api.PracticeController do
  @moduledoc """
  A practice session, as JSON:

      GET  /papi/practice           what to put in front of the player next
      POST /papi/practice/more      KEEP GOING: more new ones, then the session
      POST /papi/practice/tz        {tz} -- where this browser is
      POST /papi/practice/bury      {id} -- back tomorrow, level kept

  Every decision -- an account's deck against a guest's mistakes, due
  before new, how big a page is, which timezone names are names -- belongs
  to `oskol/handlers/practice` and `oskol/practice/deck`. This turns a conn
  into a context and a session and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def index(conn, _params) do
    send_json(conn, :oskol@handlers@practice.practice_json(ctx(), session(conn)))
  end

  def more(conn, _params) do
    send_json(conn, :oskol@handlers@practice.more_json(ctx(), session(conn)))
  end

  def tz(conn, params) do
    send_json(
      conn,
      :oskol@handlers@practice.timezone_json(ctx(), session(conn), param(params, "tz"))
    )
  end

  def bury(conn, params) do
    send_json(
      conn,
      :oskol@handlers@practice.bury_json(ctx(), session(conn), param(params, "id"))
    )
  end

  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

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
