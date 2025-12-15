defmodule Oskol.Game do
  @moduledoc """
  Facade module for game-related functionality.
  """

  alias Oskol.Game.{GameServer, GameSupervisor}

  # GameSupervisor operations
  defdelegate start_game(game_id), to: GameSupervisor
  defdelegate find_game(game_id), to: GameSupervisor
  defdelegate find_or_start_game(game_id), to: GameSupervisor

  @doc """
  Looks up a game without starting it. Returns {:ok, pid} or :not_found.
  """
  def lookup_game(game_id) do
    case GameSupervisor.find_game(game_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end

  # GameServer operations
  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate rejoin_game(game_id, player_name, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate select_format(game_id, player_id, format), to: GameServer

  def start_game_session(game_id) do
    GameServer.start_game(game_id)
  end

  # Generic player action - all game actions go through this
  defdelegate player_action_async(game_id, player_id, action), to: GameServer
end
