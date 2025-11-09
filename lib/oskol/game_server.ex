defmodule Oskol.GameServer do
  use GenServer
  require Logger

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

  # Server Callbacks

  @impl true
  def init(game_id) do
    Logger.info("Starting game server for game: #{game_id}")

    state = %{
      game_id: game_id,
      players: [],
      status: :waiting,
      last_activity: System.system_time(:second)
    }

    {:ok, state, @timeout}
  end

  @impl true
  def handle_call({:join_game, player_name, player_pid}, _from, state) do
    cond do
      length(state.players) >= 2 ->
        {:reply, {:error, :game_full}, state, @timeout}

      player_exists?(state.players, player_name) ->
        {:reply, {:error, :name_taken}, state, @timeout}

      true ->
        Process.monitor(player_pid)

        player = %{
          name: player_name,
          pid: player_pid,
          connected: true
        }

        new_players = state.players ++ [player]
        new_state = %{state | players: new_players, last_activity: System.system_time(:second)}
        new_state = update_game_status(new_state)

        broadcast_state_change(new_state)

        {:reply, {:ok, new_state}, new_state, @timeout}
    end
  end

  @impl true
  def handle_call({:rejoin_game, player_name, player_pid}, _from, state) do
    case find_player_by_name(state.players, player_name) do
      nil ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      _player ->
        Process.monitor(player_pid)

        new_players =
          Enum.map(state.players, fn p ->
            if p.name == player_name do
              %{p | pid: player_pid, connected: true}
            else
              p
            end
          end)

        new_state = %{state | players: new_players, last_activity: System.system_time(:second)}
        new_state = update_game_status(new_state)

        broadcast_state_change(new_state)

        {:reply, {:ok, new_state}, new_state, @timeout}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state, @timeout}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Logger.info("Player disconnected from game: #{state.game_id}")

    new_players =
      Enum.map(state.players, fn p ->
        if p.pid == pid do
          %{p | connected: false}
        else
          p
        end
      end)

    new_state = %{state | players: new_players, last_activity: System.system_time(:second)}
    new_state = update_game_status(new_state)

    broadcast_state_change(new_state)

    {:noreply, new_state, @timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("Game #{state.game_id} timed out after 1 hour of inactivity")
    {:stop, :normal, state}
  end

  # Private Functions

  defp via_tuple(game_id) do
    {:via, Registry, {Oskol.GameRegistry, game_id}}
  end

  defp player_exists?(players, name) do
    Enum.any?(players, fn p -> p.name == name end)
  end

  defp find_player_by_name(players, name) do
    Enum.find(players, fn p -> p.name == name end)
  end

  defp update_game_status(state) do
    connected_count = Enum.count(state.players, & &1.connected)
    player_count = length(state.players)

    status =
      cond do
        connected_count == 2 and player_count == 2 -> :ready
        player_count == 2 and connected_count < 2 -> :paused
        true -> :waiting
      end

    %{state | status: status}
  end

  defp broadcast_state_change(state) do
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{state.game_id}",
      {:game_state_updated, state}
    )
  end
end
