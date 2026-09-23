defmodule OskolWeb.Api.HomeController do
  @moduledoc """
  The signed-in home, as JSON:

      GET /papi/me/home               live games, form, practice, recent
      GET /papi/me/games/graded       the next page of graded games

  Every decision — what counts as a graded game, the windows the two
  ratings are read over, the sentence in words, what a page marker may be —
  belongs to `oskol/handlers/home`, which renders the whole envelope. This
  module turns a conn into a context and a session and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def show(conn, _params) do
    send_json(conn, {:ok, :oskol@handlers@home.home_json(ctx(), session(conn))})
  end

  def graded(conn, params) do
    send_json(
      conn,
      :oskol@handlers@home.graded_json(ctx(), session(conn), param(params, "before"))
    )
  end

  # A parameter that is not a string was not typed by the client we serve;
  # it reads as absent, and a marker that is absent is not a mangled one.
  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:some, value}
      _ -> :none
    end
  end

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
