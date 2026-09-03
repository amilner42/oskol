defmodule Oskol.Game do
  @moduledoc """
  Facade for game rooms. Rooms are generic over every registered game.
  """

  alias Oskol.Game.{GameServer, GameSupervisor}

  defdelegate start_game(game_id, slug), to: GameSupervisor
  defdelegate find_game(game_id), to: GameSupervisor
  defdelegate find_or_start_game(game_id, slug), to: GameSupervisor

  def lookup_game(game_id) do
    case GameSupervisor.find_game(game_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end

  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate rejoin_game(game_id, player_name, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate configure(game_id, attrs), to: GameServer
  defdelegate request_rematch(game_id, player_id), to: GameServer
  defdelegate player_action_async(game_id, player_id, action), to: GameServer
  defdelegate player_action(game_id, player_id, action), to: GameServer

  def start_game_session(game_id), do: GameServer.start_game(game_id)
end
