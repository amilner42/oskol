defmodule Oskol.Game.GameServer do
  use GenServer
  require Logger

  alias Oskol.Game.GameServerState

  @timeout :timer.hours(1)

  # Client API

  def start_link(game_id) do
    GenServer.start_link(__MODULE__, game_id, name: via_tuple(game_id))
  end

  def join_game(game_id, player_name, player_pid \\ nil) do
    GenServer.call(via_tuple(game_id), {:join_game, player_name, player_pid})
  end

  def rejoin_game(game_id, player_name, player_pid) do
    GenServer.call(via_tuple(game_id), {:rejoin_game, player_name, player_pid})
  end

  def get_state(game_id) do
    GenServer.call(via_tuple(game_id), :get_state)
  end

  def select_format(game_id, player_id, format) do
    GenServer.call(via_tuple(game_id), {:select_format, player_id, format})
  end

  def start_game(game_id) do
    GenServer.call(via_tuple(game_id), :start_game)
  end

  def set_game_state(game_id, game_state) do
    GenServer.call(via_tuple(game_id), {:set_game_state, game_state})
  end

  # Generic player action - all game actions go through this
  def player_action_async(game_id, player_id, action) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, action})
  end

  # Server Callbacks

  @impl true
  def init(game_id) do
    Logger.info("Starting game server for game: #{game_id}")

    state = GameServerState.new(game_id)

    {:ok, state, @timeout}
  end

  @impl true
  def handle_call({:join_game, player_name, player_pid}, _from, %GameServerState{} = state) do
    cond do
      map_size(state.connections) >= 2 ->
        {:reply, {:error, :game_full}, state, @timeout}

      GameServerState.name_taken?(state, player_name) ->
        {:reply, {:error, :name_taken}, state, @timeout}

      state.game_state != nil ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        # Only monitor if we have a PID
        monitor_ref = if player_pid, do: Process.monitor(player_pid), else: nil
        player_id = generate_player_id()

        connection = %{
          name: player_name,
          pid: player_pid,
          connected: player_pid != nil,
          monitor_ref: monitor_ref
        }

        new_connections = Map.put(state.connections, player_id, connection)

        # Emit player_joined event
        new_state = %GameServerState{
          state
          | connections: new_connections,
            last_activity: System.system_time(:second)
        }

        new_state = GameServerState.update_lobby_status_with_format(new_state)

        broadcast_state_change(new_state)

        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  @impl true
  def handle_call({:rejoin_game, player_name, player_pid}, _from, %GameServerState{} = state) do
    case GameServerState.find_player_id_by_name(state, player_name) do
      nil ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      player_id ->
        old_connection = state.connections[player_id]

        # Only allow rejoin if player is disconnected
        if old_connection.connected do
          {:reply, {:error, :player_already_connected}, state, @timeout}
        else
          # Demonitor old process if it exists
          if old_connection.monitor_ref do
            Process.demonitor(old_connection.monitor_ref, [:flush])
          end

          # Monitor new process
          monitor_ref = Process.monitor(player_pid)

          updated_connection = %{
            old_connection
            | pid: player_pid,
              connected: true,
              monitor_ref: monitor_ref
          }

          new_connections = Map.put(state.connections, player_id, updated_connection)

          # Emit player_reconnected event
          new_state = %GameServerState{
            state
            | connections: new_connections,
              last_activity: System.system_time(:second)
          }

          new_state = GameServerState.update_lobby_status_with_format(new_state)

          # Don't broadcast on rejoin - rejoining player gets state in join() response
          # Broadcasting would trigger animations for other players unnecessarily
          # broadcast_state_change(new_state)

          {:reply, {:ok, player_id, new_state}, new_state, @timeout}
        end
    end
  end

  @impl true
  def handle_call({:select_format, player_id, format}, _from, %GameServerState{} = state) do
    cond do
      state.game_state != nil ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      not Map.has_key?(state.connections, player_id) ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      true ->
        # Update format selection for this player
        new_format_selections = Map.put(state.format_selections, player_id, format)

        new_state = %GameServerState{
          state
          | format_selections: new_format_selections,
            last_activity: System.system_time(:second)
        }

        # Update lobby status to check if both players agreed
        new_state = GameServerState.update_lobby_status_with_format(new_state)

        broadcast_state_change(new_state)

        {:reply, {:ok, new_state}, new_state, @timeout}
    end
  end

  @impl true
  def handle_call(:start_game, _from, %GameServerState{} = state) do
    cond do
      state.game_state != nil ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      map_size(state.connections) != 2 ->
        {:reply, {:error, :not_enough_players}, state, @timeout}

      true ->
        # Check if both players agreed on a format
        case GameServerState.check_format_agreement(state) do
          {:ok, format} ->
            # Get all game config from agreed format
            {initial_lives, hands_per_round, discards_per_round, shop_rounds} =
              GameServerState.format_to_config(format)

            # Create player_names map from connections
            player_names =
              state.connections
              |> Enum.map(fn {player_id, connection} -> {player_id, connection.name} end)
              |> Map.new()

            # Use Gleam engine to create game state
            game_state =
              Oskol.Game.GleamEngine.new_game(
                player_names,
                initial_lives,
                hands_per_round,
                discards_per_round,
                shop_rounds
              )

            new_state = %GameServerState{
              state
              | game_state: game_state
            }

            broadcast_state_change(new_state)

            {:reply, {:ok, new_state}, new_state, @timeout}

          :no_agreement ->
            {:reply, {:error, :no_format_agreement}, state, @timeout}
        end
    end
  end

  @impl true
  def handle_call({:set_game_state, game_state}, _from, %GameServerState{} = state) do
    new_state = %GameServerState{state | game_state: game_state}
    broadcast_state_change(new_state)
    {:reply, :ok, new_state, @timeout}
  end

  @impl true
  def handle_call(:get_state, _from, %GameServerState{} = state) do
    {:reply, state, state, @timeout}
  end

  @impl true
  def handle_cast({:player_action, player_id, action}, %GameServerState{} = state) do
    # Check if game has started and player is connected
    cond do
      state.game_state == nil ->
        # Game not started, ignore action
        {:noreply, state, @timeout}

      not Map.has_key?(state.connections, player_id) ->
        # Player not found, ignore action
        {:noreply, state, @timeout}

      not state.connections[player_id].connected ->
        # Player disconnected, ignore action
        {:noreply, state, @timeout}

      true ->
        # Pass action directly to Gleam engine - no translation!
        {new_game_state, _events} =
          Oskol.Game.GleamEngine.apply_action(state.game_state, {player_id, action})

        new_state = %GameServerState{
          state
          | game_state: new_game_state,
            last_activity: System.system_time(:second)
        }

        broadcast_state_change(new_state)
        {:noreply, new_state, @timeout}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %GameServerState{} = state) do
    # Find which player disconnected
    player_id =
      Enum.find_value(state.connections, fn {pid, conn} ->
        if conn.monitor_ref == ref, do: pid, else: nil
      end)

    if player_id do
      Logger.info("Player #{player_id} disconnected from game: #{state.game_id}")

      updated_connection = %{state.connections[player_id] | connected: false}
      new_connections = Map.put(state.connections, player_id, updated_connection)

      # Emit player_disconnected event
      new_state = %GameServerState{
        state
        | connections: new_connections,
          last_activity: System.system_time(:second)
      }

      new_state = GameServerState.update_lobby_status_with_format(new_state)

      broadcast_state_change(new_state)

      {:noreply, new_state, @timeout}
    else
      {:noreply, state, @timeout}
    end
  end

  @impl true
  def handle_info(:timeout, %GameServerState{} = state) do
    Logger.info("Game #{state.game_id} timed out after 1 hour of inactivity")
    {:stop, :normal, state}
  end

  # Private Functions

  defp via_tuple(game_id) do
    {:via, Registry, {Oskol.GameRegistry, game_id}}
  end

  defp generate_player_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp broadcast_state_change(%GameServerState{} = state) do
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{state.game_id}",
      {:game_state_updated, state}
    )
  end
end
