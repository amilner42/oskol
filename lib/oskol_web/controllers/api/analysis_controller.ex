defmodule OskolWeb.Api.AnalysisController do
  @moduledoc """
  The analysis board's questions to the engine, as JSON:

      POST /papi/analysis        ask about a set-up position
      GET  /papi/analysis/:key   where that ask stands
      POST /papi/analysis/moves  every legal play of a set-up roll (no engine)
      POST /papi/analysis/rolls  how each of the 21 rolls fares from a board,
                                 and two candidate plays against each other

  Every decision -- whether the position can be asked, whether it has been
  answered already, whose budget it costs, what each refusal says -- is
  `oskol/handlers/analysis`, which renders the whole envelope. This module
  turns a conn into a context and a session, reads the asker's memory of a
  key for the GET, and writes the bytes.
  """
  use OskolWeb, :controller

  alias Oskol.Analysis.Asker
  alias Oskol.Gleam.CtxBuilder

  def create(conn, _params) do
    # The setup as the client sent it, back to text: Gleam reads the wire
    # shape (`analysis/setup.decoder`) and nothing here looks inside.
    body = Jason.encode!(conn.body_params)

    case :oskol@handlers@analysis.ask_json(CtxBuilder.build(), CtxBuilder.session(conn), body) do
      {:ok, {status, json}} -> json_resp(conn, status, json)
      {:error, error} -> error_resp(conn, error)
    end
  end

  # The legal plays of a set-up position's roll, for the line played out
  # on the board: move generation in Gleam, never the engine.
  def moves(conn, _params) do
    body = Jason.encode!(conn.body_params)

    case :oskol@handlers@analysis.moves_json(CtxBuilder.build(), CtxBuilder.session(conn), body) do
      {:ok, json} -> json_resp(conn, 200, json)
      {:error, error} -> error_resp(conn, error)
    end
  end

  # Per-roll grids, answered in the request: a grid is about 0.2 s of engine
  # time, so there is no job to join and nothing to poll. Gleam decides what is
  # asked, on which cube and from which side; `Oskol.Analysis.Rolls` makes the
  # call and keeps the answer.
  def rolls(conn, _params) do
    body = Jason.encode!(conn.body_params)

    case :oskol@handlers@analysis.rolls_json(CtxBuilder.build(), CtxBuilder.session(conn), body) do
      {:ok, json} -> json_resp(conn, 200, json)
      {:error, error} -> error_resp(conn, error)
    end
  end

  def show(conn, %{"key" => key}) do
    case :oskol@handlers@analysis.status_json(CtxBuilder.build(), key, Asker.job(key)) do
      {:ok, json} -> json_resp(conn, 200, json)
      {:error, error} -> error_resp(conn, error)
    end
  end

  defp error_resp(conn, error) do
    {status, body} = :oskol@core@envelope.error(error)
    json_resp(conn, status, body)
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
