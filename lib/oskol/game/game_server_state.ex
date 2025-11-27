defmodule Oskol.Game.GameServerState do
  @moduledoc """
  Represents the state of a game server process.
  This tracks the process-level concerns (connections, PIDs, monitors)
  while GameState handles the pure game logic.
  """

  alias Oskol.Game.GameState
  alias Oskol.Game.EventLog

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
          game_state: GameState.t() | nil,
          connections: %{player_id() => connection()},
          lobby_status: lobby_status(),
          last_activity: integer(),
          event_log: EventLog.t(),
          format_selections: %{player_id() => game_format()},
          dev_codes: [String.t()]
        }

  defstruct game_id: nil,
            game_state: nil,
            connections: %{},
            lobby_status: :waiting_for_players,
            last_activity: 0,
            event_log: nil,
            format_selections: %{},
            dev_codes: []

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
      event_log: EventLog.new(),
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
  Handles a player action by validating the player connection and delegating to GameState.
  Returns {:ok, updated_state} or {:error, reason}.

  The updated state includes both the new game_state and appended events to the event_log.
  """
  @spec handle_player_action(t(), player_id(), term()) ::
          {:ok, t()}
          | {:error, :game_not_started | :player_not_found | :player_disconnected | term()}
  def handle_player_action(%__MODULE__{game_state: nil}, _player_id, _action) do
    {:error, :game_not_started}
  end

  def handle_player_action(%__MODULE__{} = state, player_id, action) do
    case Map.get(state.connections, player_id) do
      nil ->
        {:error, :player_not_found}

      %{connected: false} ->
        {:error, :player_disconnected}

      _connection ->
        case perform_action(state.game_state, player_id, action) do
          {:ok, updated_game_state, event_descriptions} ->
            # Append events to event log
            updated_event_log =
              Enum.reduce(event_descriptions, state.event_log, fn {type, pid, data}, log ->
                EventLog.append(log, state.game_id, type, pid, data)
              end)

            {:ok,
             %__MODULE__{
               state
               | game_state: updated_game_state,
                 event_log: updated_event_log,
                 last_activity: System.system_time(:second)
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Private function that delegates actions to GameState
  # Returns {:ok, new_game_state, event_descriptions} or {:error, reason}
  defp perform_action(game_state, player_id, {:lock_in_hand, hand}) do
    {new_state, events} = GameState.player_lock_in_hand(game_state, player_id, hand)
    {:ok, new_state, events}
  end

  defp perform_action(game_state, player_id, {:discard_cards, cards}) do
    GameState.player_discard_cards(game_state, player_id, cards)
  end

  defp perform_action(game_state, player_id, :mark_ready_for_next_round) do
    {new_state, events} = GameState.mark_ready_for_next_round(game_state, player_id)
    {:ok, new_state, events}
  end

  defp perform_action(game_state, player_id, {:make_shop_pick, upgrade_index}) do
    GameState.make_shop_pick(game_state, player_id, upgrade_index)
  end

  defp perform_action(game_state, player_id, {:confirm_deck_builder_pick, shop_card_index}) do
    GameState.confirm_deck_builder_pick(game_state, player_id, shop_card_index)
  end

  defp perform_action(game_state, player_id, {:complete_deck_builder_selection, selected_card_id}) do
    GameState.complete_deck_builder_selection(game_state, player_id, selected_card_id)
  end

  defp perform_action(game_state, player_id, :skip_deck_builder_selection) do
    GameState.skip_deck_builder_selection(game_state, player_id)
  end

  defp perform_action(_game_state, _player_id, action) do
    {:error, {:unknown_action, action}}
  end

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
