defmodule Oskol.Game.GameServer do
  use GenServer
  require Logger

  alias Oskol.Game.{GameState, GameServerState, EventLog}

  @timeout :timer.hours(1)

  # Client API

  def start_link(game_id) do
    GenServer.start_link(__MODULE__, game_id, name: via_tuple(game_id))
  end

  def join_game(game_id, player_name, player_pid) do
    GenServer.call(via_tuple(game_id), {:join_game, player_name, player_pid})
  end

  def rejoin_game(game_id, player_name, player_pid) do
    GenServer.call(via_tuple(game_id), {:rejoin_game, player_name, player_pid})
  end

  def get_state(game_id) do
    GenServer.call(via_tuple(game_id), :get_state)
  end

  def start_game(game_id, initial_lives \\ 3) do
    GenServer.call(via_tuple(game_id), {:start_game, initial_lives})
  end

  def lock_in_hand(game_id, player_id, hand) do
    GenServer.call(via_tuple(game_id), {:player_action, player_id, {:lock_in_hand, hand}})
  end

  def lock_in_hand_async(game_id, player_id, hand) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, {:lock_in_hand, hand}})
  end

  def unlock_hand_async(game_id, player_id) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, :unlock_hand})
  end

  def discard_cards_async(game_id, player_id, cards) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, {:discard_cards, cards}})
  end

  def mark_ready_for_next_round_async(game_id, player_id) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, :mark_ready_for_next_round})
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
        monitor_ref = Process.monitor(player_pid)
        player_id = generate_player_id()

        connection = %{
          name: player_name,
          pid: player_pid,
          connected: true,
          monitor_ref: monitor_ref
        }

        new_connections = Map.put(state.connections, player_id, connection)

        # Emit player_joined event
        event_log = EventLog.append(state.event_log, state.game_id, :player_joined, player_id, %{name: player_name})

        new_state = %GameServerState{
          state
          | connections: new_connections,
            last_activity: System.system_time(:second),
            event_log: event_log
        }

        new_state = GameServerState.update_lobby_status(new_state)

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

          updated_connection = %{old_connection | pid: player_pid, connected: true, monitor_ref: monitor_ref}
          new_connections = Map.put(state.connections, player_id, updated_connection)

          # Emit player_reconnected event
          event_log = EventLog.append(state.event_log, state.game_id, :player_reconnected, player_id, %{name: player_name})

          new_state = %GameServerState{
            state
            | connections: new_connections,
              last_activity: System.system_time(:second),
              event_log: event_log
          }

          new_state = GameServerState.update_lobby_status(new_state)

          broadcast_state_change(new_state)

          {:reply, {:ok, player_id, new_state}, new_state, @timeout}
        end
    end
  end

  @impl true
  def handle_call({:start_game, initial_lives}, _from, %GameServerState{} = state) do
    cond do
      state.game_state != nil ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      map_size(state.connections) != 2 ->
        {:reply, {:error, :not_enough_players}, state, @timeout}

      true ->
        # Create player_names map from connections
        player_names =
          state.connections
          |> Enum.map(fn {player_id, connection} -> {player_id, connection.name} end)
          |> Map.new()

        game_state = GameState.new(player_names, initial_lives)

        # Emit game_started event
        player_ids = Map.keys(player_names)
        event_log = EventLog.append(state.event_log, state.game_id, :game_started, nil, %{
          player_ids: player_ids,
          initial_lives: initial_lives,
          starting_round: 1
        })

        new_state = %GameServerState{state | game_state: game_state, event_log: event_log}

        broadcast_state_change(new_state)

        {:reply, {:ok, new_state}, new_state, @timeout}
    end
  end

  @impl true
  def handle_call(:get_state, _from, %GameServerState{} = state) do
    {:reply, state, state, @timeout}
  end

  @impl true
  def handle_call({:player_action, player_id, action}, _from, %GameServerState{} = state) do
    case GameServerState.handle_player_action(state, player_id, action) do
      {:ok, new_state} ->
        broadcast_state_change(new_state)
        {:reply, {:ok, new_state}, new_state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  @impl true
  def handle_cast({:player_action, player_id, action}, %GameServerState{} = state) do
    case GameServerState.handle_player_action(state, player_id, action) do
      {:ok, new_state} ->
        broadcast_state_change(new_state)
        {:noreply, new_state, @timeout}

      {:error, reason} ->
        broadcast_action_failed(state, player_id, reason)
        {:noreply, state, @timeout}
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
      event_log = EventLog.append(state.event_log, state.game_id, :player_disconnected, player_id, %{
        name: updated_connection.name
      })

      new_state = %GameServerState{
        state
        | connections: new_connections,
          last_activity: System.system_time(:second),
          event_log: event_log
      }

      new_state = GameServerState.update_lobby_status(new_state)

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

  defp broadcast_action_failed(%GameServerState{} = state, player_id, reason) do
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{state.game_id}",
      {:action_failed, player_id, reason}
    )
  end
end
