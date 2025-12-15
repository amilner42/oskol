defmodule Oskol.Game.GameServerState do
  @moduledoc """
  Represents the state of a game server process.
  This tracks the process-level concerns (connections, PIDs, monitors)
  while Gleam handles the pure game logic.
  """

  @type game_id :: String.t()
  @type player_id :: String.t()
  @type lobby_status :: :waiting_for_players | :ready_to_start
  @type game_format :: :short | :standard | :extended

  @type connection :: %{
          name: String.t(),
          pid: pid(),
          connected: boolean(),
          monitor_ref: reference() | nil
        }

  @type t :: %__MODULE__{
          game_id: game_id(),
          game_state: term() | nil,
          connections: %{player_id() => connection()},
          lobby_status: lobby_status(),
          last_activity: integer(),
          format_selections: %{player_id() => game_format()}
        }

  defstruct game_id: nil,
            game_state: nil,
            connections: %{},
            lobby_status: :waiting_for_players,
            last_activity: 0,
            format_selections: %{}

  @doc """
  Creates a new game server state for the given game_id.
  """
  @spec new(game_id()) :: t()
  def new(game_id) do
    %__MODULE__{
      game_id: game_id,
      game_state: nil,
      connections: %{},
      lobby_status: :waiting_for_players,
      last_activity: System.system_time(:second),
      format_selections: %{}
    }
  end

  @doc """
  Checks if a player name is already taken in the connections.
  """
  @spec name_taken?(t(), String.t()) :: boolean()
  def name_taken?(%__MODULE__{connections: connections}, name) do
    connections
    |> Map.values()
    |> Enum.any?(fn conn -> conn.name == name end)
  end

  @doc """
  Finds a player_id by their name. Returns nil if not found.
  """
  @spec find_player_id_by_name(t(), String.t()) :: player_id() | nil
  def find_player_id_by_name(%__MODULE__{connections: connections}, name) do
    Enum.find_value(connections, fn {player_id, conn} ->
      if conn.name == name, do: player_id, else: nil
    end)
  end

  @doc """
  Updates the lobby status based on current connections.
  Only updates if the game hasn't started yet.
  """
  @spec update_lobby_status(t()) :: t()
  def update_lobby_status(%__MODULE__{game_state: nil} = state) do
    connected_count = Enum.count(state.connections, fn {_id, conn} -> conn.connected end)
    player_count = map_size(state.connections)

    lobby_status =
      cond do
        connected_count == 2 and player_count == 2 -> :ready_to_start
        true -> :waiting_for_players
      end

    %__MODULE__{state | lobby_status: lobby_status}
  end

  def update_lobby_status(%__MODULE__{} = state), do: state

  @doc """
  Converts a game format to its configuration (lives, shop_rounds).
  """
  @spec format_to_config(game_format()) :: {pos_integer(), non_neg_integer()}
  def format_to_config(:short), do: {2, 1}
  def format_to_config(:standard), do: {3, 2}
  def format_to_config(:extended), do: {5, 2}

  @doc """
  Checks if both players have selected the same format.
  Returns {:ok, format} if agreed, :no_agreement if different or missing.
  """
  @spec check_format_agreement(t()) :: {:ok, game_format()} | :no_agreement
  def check_format_agreement(%__MODULE__{format_selections: selections, connections: connections}) do
    # Need exactly 2 players and 2 format selections
    if map_size(connections) == 2 and map_size(selections) == 2 do
      formats = Map.values(selections)
      [format1, format2] = formats

      if format1 == format2 do
        {:ok, format1}
      else
        :no_agreement
      end
    else
      :no_agreement
    end
  end

  @doc """
  Updates lobby status to include format agreement check.
  """
  @spec update_lobby_status_with_format(t()) :: t()
  def update_lobby_status_with_format(%__MODULE__{game_state: nil} = state) do
    connected_count = Enum.count(state.connections, fn {_id, conn} -> conn.connected end)
    player_count = map_size(state.connections)

    lobby_status =
      cond do
        connected_count == 2 and player_count == 2 and
            match?({:ok, _}, check_format_agreement(state)) ->
          :ready_to_start

        true ->
          :waiting_for_players
      end

    %__MODULE__{state | lobby_status: lobby_status}
  end

  def update_lobby_status_with_format(%__MODULE__{} = state), do: state
end
