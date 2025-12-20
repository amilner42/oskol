defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  alias Oskol.Game.{GameServer, GameServerState, GleamEngine}

  def home(conn, _params) do
    render(conn, :home)
  end

  def elm_game(conn, %{"id" => game_id} = params) do
    # Try to get player_id from multiple sources in priority order
    {player_id, disconnected_players} = resolve_player_id(conn, game_id, params)

    # Store player_id in session for future requests
    conn =
      if player_id do
        put_session(conn, :player_id, player_id)
      else
        conn
      end

    render(conn, :elm_game,
      layout: false,
      game_id: game_id,
      player_id: player_id,
      disconnected_players: disconnected_players
    )
  end

  # Resolve player_id from session, URL params, or connections
  # Returns {player_id, disconnected_players}
  defp resolve_player_id(conn, game_id, params) do
    try do
      game_server_state = GameServer.get_state(game_id)

      # Get list of disconnected players for reconnect UI
      disconnected_players =
        game_server_state.connections
        |> Enum.filter(fn {_id, conn} -> not conn.connected end)
        |> Enum.map(fn {id, conn} -> %{id: id, name: conn.name} end)

      # Priority 1: Check session for existing player_id
      session_player_id = get_session(conn, :player_id)

      if session_player_id && Map.has_key?(game_server_state.connections, session_player_id) do
        {session_player_id, disconnected_players}
      else
        # Priority 2: Look up by name from URL params
        case params["name"] do
          nil ->
            {nil, disconnected_players}

          name ->
            # First try connections (works before and after game start)
            player_id = GameServerState.find_player_id_by_name(game_server_state, name)

            # Fallback to game_state player_names if not found in connections
            player_id =
              player_id ||
                if game_server_state.game_state do
                  player_names = GleamEngine.get_player_names(game_server_state.game_state)

                  Enum.find_value(player_names, fn {pid, player_name} ->
                    if player_name == name, do: pid, else: nil
                  end)
                end

            {player_id, disconnected_players}
        end
      end
    catch
      :exit, _ ->
        # Game doesn't exist
        {nil, []}
    end
  end
end
