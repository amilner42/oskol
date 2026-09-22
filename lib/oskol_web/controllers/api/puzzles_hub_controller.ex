defmodule OskolWeb.Api.PuzzlesHubController do
  @moduledoc """
  The practice home's own endpoint:

      GET /papi/puzzles/random     TRY ONE: a puzzle whose answer stands clear

  Which puzzle qualifies is `oskol/handlers/puzzles_hub`'s rule; this turns
  a conn into a context and writes the bytes. The session is not read: the
  answer is the same whoever asks, and nothing is written.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def random(conn, _params) do
    send_json(conn, :oskol@handlers@puzzles_hub.random_json(CtxBuilder.build()))
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
