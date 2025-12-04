defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def elm_test(conn, _params) do
    render(conn, :elm_test, layout: false)
  end

  def elm_game(conn, %{"id" => game_id} = params) do
    # Try to get player_id from session first
    player_id = case get_session(conn, :player_id) do
      nil ->
        # If not in session, try to look up by name from game state
        case params["name"] do
          nil -> nil
          name ->
            # Get game state and find player_id by name
            try do
              game_server_state = Oskol.Game.GameServer.get_state(game_id)

              # If game has started, look up player_id from player_names
              if game_server_state.game_state do
                # Find the player_id where the name matches
                Enum.find_value(game_server_state.game_state.player_names, fn {pid, player_name} ->
                  if player_name == name, do: pid, else: nil
                end)
              else
                nil
              end
            catch
              :exit, _ -> nil
            end
        end
      session_player_id ->
        session_player_id
    end

    render(conn, :elm_game,
      layout: false,
      game_id: game_id,
      player_id: player_id
    )
  end
end
