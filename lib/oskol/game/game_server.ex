defmodule Oskol.Game.GameServer do
  @moduledoc """
  One process per game room. Generic over every registered game: it owns the
  connections, the creator's setup, and an opaque game instance that it
  drives through `Oskol.GameKit`.

  The creator sets the room up (format, settings, clock) and shares a link;
  the game starts the moment the table is full.
  """
  # Rooms hold their whole state in memory, so a restart could only ever
  # produce an empty room with a taken id: an idle stop is final.
  use GenServer, restart: :temporary
  require Logger

  alias Oskol.Game.GameServerState
  alias Oskol.GameKit

  @timeout :timer.hours(1)

  # ---------- Client API ----------

  def start_link({game_id, slug}) do
    GenServer.start_link(__MODULE__, {game_id, slug}, name: via_tuple(game_id))
  end

  def join_game(game_id, player_name, player_pid \\ nil) do
    GenServer.call(via_tuple(game_id), {:join_game, player_name, player_pid})
  end

  def rejoin_game(game_id, player_name, player_pid) do
    GenServer.call(via_tuple(game_id), {:rejoin_game, player_name, player_pid})
  end

  def get_state(game_id), do: GenServer.call(via_tuple(game_id), :get_state)

  @doc """
  Set the room up before it starts: `%{format: id, selections: %{setting => choice},
  clock: preset_id}`, plus `seed:` and `control:` for tests and tooling.
  """
  def configure(game_id, attrs) when is_map(attrs) do
    GenServer.call(via_tuple(game_id), {:configure, attrs})
  end

  @doc """
  Start the game explicitly. Rooms start on their own when the table fills;
  this is for tooling and for rooms whose setup allows fewer players.
  """
  def start_game(game_id, seed \\ nil, control \\ nil) do
    GenServer.call(via_tuple(game_id), {:start_game, seed, control})
  end

  @doc "Apply a client action asynchronously. Failures are broadcast as `{:action_failed, player_id, reason}`."
  def player_action_async(game_id, player_id, action) when is_map(action) do
    GenServer.cast(via_tuple(game_id), {:player_action, player_id, action})
  end

  @doc "Synchronous variant used by tests and tooling."
  def player_action(game_id, player_id, action) when is_map(action) do
    GenServer.call(via_tuple(game_id), {:player_action, player_id, action})
  end

  def request_rematch(game_id, player_id) do
    GenServer.call(via_tuple(game_id), {:request_rematch, player_id})
  end

  # ---------- Server ----------

  @impl true
  def init({game_id, slug}) do
    Logger.info("Starting #{slug} game server: #{game_id}")
    {:ok, GameServerState.new(game_id, slug), @timeout}
  end

  @impl true
  def handle_call({:configure, attrs}, _from, %GameServerState{} = state) do
    cond do
      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        case GameServerState.validate_setup(state, attrs) do
          {:ok, setup} ->
            new_state = %GameServerState{state | setup: setup} |> GameServerState.touch()
            broadcast(new_state, [])
            {:reply, {:ok, new_state}, new_state, @timeout}

          {:error, reason} ->
            {:reply, {:error, reason}, state, @timeout}
        end
    end
  end

  def handle_call({:join_game, player_name, player_pid}, _from, %GameServerState{} = state) do
    cond do
      GameServerState.full?(state) ->
        {:reply, {:error, :game_full}, state, @timeout}

      GameServerState.name_taken?(state, player_name) ->
        {:reply, {:error, :name_taken}, state, @timeout}

      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        monitor_ref = if player_pid, do: Process.monitor(player_pid), else: nil
        player_id = generate_player_id()

        connection = %{
          name: player_name,
          pid: player_pid,
          connected: player_pid != nil,
          monitor_ref: monitor_ref
        }

        new_state =
          %GameServerState{
            state
            | connections: Map.put(state.connections, player_id, connection),
              seat_order: state.seat_order ++ [player_id]
          }
          |> GameServerState.touch()
          |> GameServerState.update_lobby_status()

        # The table is full: the game starts right away.
        new_state =
          if GameServerState.full?(new_state) do
            case do_start(new_state, nil, nil) do
              {:ok, started} -> started
              {:error, _} -> new_state
            end
          else
            new_state
          end

        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call({:rejoin_game, player_name, player_pid}, _from, %GameServerState{} = state) do
    case GameServerState.find_player_id_by_name(state, player_name) do
      nil ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      player_id ->
        old = state.connections[player_id]

        # The newest channel is the live one, even when the previous socket
        # has not timed out yet (a phone coming back before the old
        # websocket closed): its monitor is dropped so the old socket's exit
        # cannot mark a present player as away.
        if old.monitor_ref, do: Process.demonitor(old.monitor_ref, [:flush])
        monitor_ref = Process.monitor(player_pid)
        updated = %{old | pid: player_pid, connected: true, monitor_ref: monitor_ref}

        new_state =
          %GameServerState{state | connections: Map.put(state.connections, player_id, updated)}
          |> GameServerState.touch()
          |> GameServerState.update_lobby_status()

        # The rejoining client gets the state in its reply; everyone else
        # learns the seat is live again.
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call({:start_game, seed, control}, _from, %GameServerState{} = state) do
    case do_start(state, seed, control) do
      {:ok, new_state} ->
        broadcast(new_state, [])
        {:reply, {:ok, new_state}, new_state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:player_action, player_id, action}, _from, %GameServerState{} = state) do
    case apply_action(state, player_id, action) do
      {:ok, new_state, events} ->
        broadcast(new_state, events)
        {:reply, {:ok, new_state, events}, new_state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:request_rematch, player_id}, _from, %GameServerState{} = state) do
    cond do
      not GameServerState.started?(state) or not GameKit.finished?(state.instance) ->
        {:reply, {:error, :game_not_finished}, state, @timeout}

      not Map.has_key?(state.connections, player_id) ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      state.rematch_game_id != nil ->
        {:reply, {:ok, state.rematch_game_id}, state, @timeout}

      true ->
        ready = MapSet.put(state.rematch_ready, player_id)
        new_state = %GameServerState{state | rematch_ready: ready} |> GameServerState.touch()

        if MapSet.size(ready) == map_size(state.connections) do
          rematch_id = rematch_id(state.game_id)
          :ok = spawn_rematch(rematch_id, state)
          new_state = %GameServerState{new_state | rematch_game_id: rematch_id}
          broadcast(new_state, [])

          Phoenix.PubSub.broadcast(
            Oskol.PubSub,
            topic(state.game_id),
            {:rematch_ready, rematch_id}
          )

          {:reply, {:ok, rematch_id}, new_state, @timeout}
        else
          broadcast(new_state, [])
          {:reply, {:ok, nil}, new_state, @timeout}
        end
    end
  end

  def handle_call(:get_state, _from, %GameServerState{} = state) do
    {:reply, state, state, @timeout}
  end

  @impl true
  def handle_cast({:player_action, player_id, action}, %GameServerState{} = state) do
    case apply_action(state, player_id, action) do
      {:ok, new_state, events} ->
        broadcast(new_state, events)
        {:noreply, new_state, @timeout}

      {:error, reason} ->
        Phoenix.PubSub.broadcast(
          Oskol.PubSub,
          topic(state.game_id),
          {:action_failed, player_id, to_string(reason)}
        )

        {:noreply, state, @timeout}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %GameServerState{} = state) do
    player_id =
      Enum.find_value(state.connections, fn {id, conn} ->
        if conn.monitor_ref == ref, do: id, else: nil
      end)

    if player_id do
      Logger.info("Player #{player_id} disconnected from game: #{state.game_id}")
      updated = %{state.connections[player_id] | connected: false}

      new_state =
        %GameServerState{state | connections: Map.put(state.connections, player_id, updated)}
        |> GameServerState.touch()
        |> GameServerState.update_lobby_status()

      broadcast(new_state, [])
      {:noreply, new_state, @timeout}
    else
      {:noreply, state, @timeout}
    end
  end

  # Clock-driven turns are not activity: a table both players walked away
  # from must still go idle, even if the clock keeps dealing hands.
  def handle_info(:clock_tick, %GameServerState{} = state) do
    state = %GameServerState{state | clock_timer: nil}

    if GameServerState.idle?(state, @timeout) do
      handle_info(:timeout, state)
    else
      case state.instance && GameKit.expire(state.instance, GameKit.now()) do
        {:ok, instance, events} ->
          new_state =
            %GameServerState{state | instance: instance}
            |> schedule_clock_tick()

          broadcast(new_state, events)
          {:noreply, new_state, @timeout}

        _ ->
          {:noreply, schedule_clock_tick(state), @timeout}
      end
    end
  end

  def handle_info(:timeout, %GameServerState{} = state) do
    Logger.info("Game #{state.game_id} timed out after 1 hour of inactivity")
    {:stop, :normal, state}
  end

  # ---------- Private ----------

  defp do_start(%GameServerState{} = state, seed, control) do
    setup = state.setup

    with false <- GameServerState.started?(state),
         true <- map_size(state.connections) >= GameServerState.min_players(state),
         seed <- seed || setup.seed || :rand.uniform(2_147_483_647),
         control <- control || setup.control || GameKit.clock_control(setup.clock),
         {:ok, instance} <-
           GameKit.start(
             state.slug,
             setup.format,
             GameServerState.seats(state),
             seed,
             control,
             GameKit.now(),
             Map.to_list(setup.selections)
           ) do
      new_state =
        %GameServerState{state | instance: instance, seed: seed}
        |> GameServerState.touch()
        |> schedule_clock_tick()

      {:ok, new_state}
    else
      true -> {:error, :game_already_started}
      false -> {:error, :not_enough_players}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_action(%GameServerState{} = state, player_id, action) do
    cond do
      not GameServerState.started?(state) ->
        {:error, :game_not_started}

      not Map.has_key?(state.connections, player_id) ->
        {:error, :player_not_found}

      true ->
        case GameKit.apply(state.instance, player_id, action, GameKit.now()) do
          {:ok, instance, events} ->
            new_state =
              %GameServerState{state | instance: instance}
              |> GameServerState.touch()
              |> schedule_clock_tick()

            {:ok, new_state, events}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A rematch is a new room with the same setup (fresh seed) and the same
  # names; the second join starts it.
  defp spawn_rematch(rematch_id, %GameServerState{} = state) do
    case Oskol.Game.GameSupervisor.start_game(rematch_id, state.slug) do
      {:ok, _pid} ->
        {:ok, _} = configure(rematch_id, %{state.setup | seed: nil})

        Enum.each(GameServerState.seats(state), fn {_old_id, name} ->
          {:ok, _new_id, _} = join_game(rematch_id, name, nil)
        end)

        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp rematch_id(current_id) do
    case Regex.run(~r/^(.+)-r(\d+)$/, current_id) do
      [_, base, n] -> "#{base}-r#{String.to_integer(n) + 1}"
      nil -> "#{current_id}-r1"
    end
  end

  # Arrange to be woken when the earliest running clock could hit zero.
  defp schedule_clock_tick(%GameServerState{} = state) do
    if state.clock_timer, do: Process.cancel_timer(state.clock_timer)

    case state.instance && GameKit.next_deadline(state.instance, GameKit.now()) do
      {:ok, ms} ->
        ref = Process.send_after(self(), :clock_tick, max(ms, 0) + 20)
        %GameServerState{state | clock_timer: ref}

      _ ->
        %GameServerState{state | clock_timer: nil}
    end
  end

  defp via_tuple(game_id), do: {:via, Registry, {Oskol.GameRegistry, game_id}}

  defp topic(game_id), do: "game:#{game_id}"

  defp generate_player_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp broadcast(%GameServerState{} = state, events) do
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      topic(state.game_id),
      {:game_state_updated, state, events}
    )
  end
end
