defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.GameKit

  @doc """
  Serves the Elm client for a running game.

  The `t` param is the seat token, and it is the only way in: it is handed
  to the page so the client can authenticate its channel join. Without a
  valid one there is nothing to serve — not even a spectator's view of the
  table — so the visitor goes to the invite link, which decides whether
  there is a seat for them at all.
  """
  def play(conn, %{"slug" => slug, "id" => game_id} = params) do
    cond do
      not GameKit.exists?(slug) ->
        conn |> put_status(:not_found) |> put_view(OskolWeb.ErrorHTML) |> render(:"404")

      player_id = seat_for_token(game_id, params["t"]) ->
        render(conn, :elm_game,
          layout: false,
          game_id: game_id,
          slug: slug,
          player_id: player_id,
          seat_token: params["t"]
        )

      true ->
        redirect(conn, to: ~p"/#{slug}?game=#{game_id}")
    end
  end

  defp seat_for_token(_game_id, nil), do: nil

  defp seat_for_token(game_id, token) do
    case Game.lookup_game(game_id) do
      {:ok, _pid} ->
        game_id
        |> Game.get_server_state()
        |> GameServerState.find_player_id_by_token(token)

      _ ->
        nil
    end
  catch
    :exit, _ -> nil
  end
end
