defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  alias Oskol.Game.GameServerState
  alias Oskol.GameKit

  @doc "Serves the Elm client for a running game."
  def play(conn, %{"slug" => slug, "id" => game_id} = params) do
    if GameKit.exists?(slug) do
      player_id = get_session(conn, :player_id) || player_id_from_name(game_id, params["name"])

      render(conn, :elm_game,
        layout: false,
        game_id: game_id,
        slug: slug,
        player_id: player_id
      )
    else
      conn |> put_status(:not_found) |> put_view(OskolWeb.ErrorHTML) |> render(:"404")
    end
  end

  defp player_id_from_name(_game_id, nil), do: nil

  defp player_id_from_name(game_id, name) do
    try do
      game_id
      |> Oskol.Game.GameServer.get_state()
      |> GameServerState.find_player_id_by_name(name)
    catch
      :exit, _ -> nil
    end
  end
end
