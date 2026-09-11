defmodule Oskol.Game.GameServer do
  @moduledoc """
  One process per game room. Generic over every registered game: it owns the
  connections, the creator's setup, and an opaque game instance that it
  drives through `Oskol.GameKit`.

  The creator sets the room up (format, settings, clock) and shares a link;
  the game starts the moment the table is full.
  """
  # Rooms hold their whole state in memory; the database holds the durable
  # picture (seed + action log, written behind by Oskol.Game.Persister). A
  # crashed or idle-stopped room is not restarted here: the next lookup
  # rehydrates it from the log (Oskol.Game.Rehydrator), so an idle stop is
  # graceful, not final.
  use GenServer, restart: :temporary
  require Logger

  alias Oskol.Game.GameServerState
  alias Oskol.Game.Persister
  alias Oskol.GameKit

  @timeout :timer.hours(1)

  # ---------- Client API ----------

  def start_link({game_id, slug}) do
    GenServer.start_link(__MODULE__, {game_id, slug}, name: via_tuple(game_id))
  end

  def start_link({game_id, slug, restore}) do
    GenServer.start_link(__MODULE__, {game_id, slug, restore}, name: via_tuple(game_id))
  end

  @doc """
  Take a free seat. Mints the seat's token; the caller reads it back with
  `GameServerState.token_for/2`. The display name is display only.
  `guest_id` is the visitor's guest-cookie id, recorded on the seat purely
  for bookkeeping: it grants nothing.
  """
  def join_game(game_id, player_name, player_pid \\ nil, guest_id \\ nil) do
    GenServer.call(via_tuple(game_id), {:join_game, player_name, player_pid, guest_id})
  end

  @doc """
  Attach a connection to the seat a token opens.

  This is the only way to reach a seat with an already-connected player: a
  second connection bearing the same valid token is the same person, so the
  latest one wins and the previous socket is dropped. A wrong or stale token
  is `{:error, :invalid_token}` — it never falls back to any other seat.

  `client` identifies the browser behind the connection (the socket's
  transport, which outlives any one channel), and it is what tells a
  reconnect from a takeover: see `src/oskol/rooms/seat.gleam`. Callers with
  nothing better to offer pass the connection itself.
  """
  def attach(game_id, token, player_pid, client \\ nil) do
    GenServer.call(via_tuple(game_id), {:attach, token, player_pid, client || player_pid})
  end

  @doc """
  Reclaim a seat whose player is away, from the invite link. Rotates that
  seat's token before attaching, so a link that leaked earlier cannot
  silently shadow the seat later. Returns `{:ok, player_id, token, state}`.
  A seat whose player is connected is `{:error, :seat_connected}`.
  """
  def claim_seat(game_id, player_id, player_pid) do
    GenServer.call(via_tuple(game_id), {:claim_seat, player_id, player_pid})
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
    state = GameServerState.new(game_id, slug)
    Persister.game_created(game_id, slug, state.setup)
    {:ok, state, @timeout}
  end

  # Rehydration: rebuild the room from its persisted row and action log.
  # Replay happens in init so no call can reach a half-restored room.
  def init({game_id, slug, {:restore, game, actions}}) do
    Logger.info("Rehydrating #{slug} game server: #{game_id} (#{length(actions)} log entries)")

    case restore_state(GameServerState.new(game_id, slug), game, actions) do
      {:ok, state} ->
        {:ok, state, @timeout}

      {:error, reason} ->
        Logger.error("Could not rehydrate game #{game_id}: #{inspect(reason)}")
        :ignore
    end
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
            Persister.game_configured(state.game_id, setup)
            broadcast(new_state, [])
            {:reply, {:ok, new_state}, new_state, @timeout}

          {:error, reason} ->
            {:reply, {:error, reason}, state, @timeout}
        end
    end
  end

  def handle_call(
        {:join_game, player_name, player_pid, guest_id},
        _from,
        %GameServerState{} = state
      ) do
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
          token: GameServerState.new_token(),
          guest_id: guest_id,
          pid: player_pid,
          client: player_pid,
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

        Persister.players_updated(new_state.game_id, players_json(new_state))

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

  def handle_call({:attach, token, player_pid, client}, _from, %GameServerState{} = state) do
    case GameServerState.find_player_id_by_token(state, token) do
      nil ->
        {:reply, {:error, :invalid_token}, state, @timeout}

      player_id ->
        new_state = do_attach(state, player_id, player_pid, client)

        # The attaching client gets the state in its reply; everyone else
        # learns the seat is live again.
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call({:claim_seat, player_id, player_pid}, _from, %GameServerState{} = state) do
    case state.connections[player_id] do
      nil ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      %{connected: true} ->
        # A seat with a live player is locked: only its token gets in.
        {:reply, {:error, :seat_connected}, state, @timeout}

      conn ->
        token = GameServerState.new_token()
        rotated = %{conn | token: token}

        state = %GameServerState{
          state
          | connections: Map.put(state.connections, player_id, rotated)
        }

        new_state = do_attach(state, player_id, player_pid, player_pid)

        # The rotated token must be on disk before it is the only way in.
        Persister.players_updated(new_state.game_id, players_json(new_state))
        broadcast(new_state, [])
        {:reply, {:ok, player_id, token, new_state}, new_state, @timeout}
    end
  end

  # A rematch is the same players in the same seats: the new room is seeded
  # with the old ids, names and tokens, so the link each player already
  # holds carries them into it.
  def handle_call(
        {:seed_seat, player_id, name, token, guest_id},
        _from,
        %GameServerState{} = state
      ) do
    connection = %{
      name: name,
      token: token,
      guest_id: guest_id,
      pid: nil,
      client: nil,
      connected: false,
      monitor_ref: nil
    }

    new_state =
      %GameServerState{
        state
        | connections: Map.put(state.connections, player_id, connection),
          seat_order: state.seat_order ++ [player_id]
      }
      |> GameServerState.touch()
      |> GameServerState.update_lobby_status()

    Persister.players_updated(new_state.game_id, players_json(new_state))
    {:reply, {:ok, player_id, new_state}, new_state, @timeout}
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
      now = GameKit.now()

      case state.instance && GameKit.expire(state.instance, now) do
        {:ok, instance, events} ->
          new_state =
            %GameServerState{state | instance: instance, action_count: state.action_count + 1}
            |> schedule_clock_tick()

          persist_entry(state, "expire", nil, nil, now)
          persist_finish(new_state)
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
    now = GameKit.now()

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
             now,
             Map.to_list(setup.selections)
           ) do
      new_state =
        %GameServerState{state | instance: instance, seed: seed, clock_base: now, action_count: 0}
        |> GameServerState.touch()
        |> schedule_clock_tick()

      Persister.game_started(state.game_id, seed, setup, players_json(new_state))
      {:ok, new_state}
    else
      true -> {:error, :game_already_started}
      false -> {:error, :not_enough_players}
      {:error, reason} -> {:error, reason}
    end
  end

  # Point a seat at a new connection. The newest connection is the live one,
  # even when the previous one has not timed out yet (a phone coming back
  # before the old websocket closed, or the same player opening a second tab
  # with their token): the old monitor is dropped so its exit cannot mark a
  # present player as away, and only one connection ever holds the seat.
  #
  # Whether the one being replaced is *told* is the seat rule in
  # `src/oskol/rooms/seat.gleam`, and it turns on the client: a client
  # rejoins its own channel routinely (its own routes, a duplicate join, a
  # socket back from a sleeping phone) and none of that is a takeover. Only
  # another live client displaces the connection that had the seat.
  defp do_attach(%GameServerState{} = state, player_id, player_pid, client) do
    old = state.connections[player_id]

    if old.monitor_ref, do: Process.demonitor(old.monitor_ref, [:flush])

    holder =
      if old.pid && Process.alive?(old.pid) && old.client, do: {:some, old.client}, else: :none

    attach = :oskol@rooms@seat.attach(holder, client)

    if :oskol@rooms@seat.displaces_holder(attach) do
      send(old.pid, :seat_taken_over)
    end

    monitor_ref = Process.monitor(player_pid)

    updated = %{
      old
      | pid: player_pid,
        client: client,
        connected: true,
        monitor_ref: monitor_ref
    }

    %GameServerState{state | connections: Map.put(state.connections, player_id, updated)}
    |> GameServerState.touch()
    |> GameServerState.update_lobby_status()
  end

  defp apply_action(%GameServerState{} = state, player_id, action) do
    cond do
      not GameServerState.started?(state) ->
        {:error, :game_not_started}

      not Map.has_key?(state.connections, player_id) ->
        {:error, :player_not_found}

      true ->
        now = GameKit.now()

        case GameKit.apply(state.instance, player_id, action, now) do
          {:ok, instance, events} ->
            new_state =
              %GameServerState{state | instance: instance, action_count: state.action_count + 1}
              |> GameServerState.touch()
              |> schedule_clock_tick()

            persist_entry(state, "action", player_id, action, now)
            persist_finish(new_state)
            {:ok, new_state, events}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Append one log entry at the room's current index, with its offset from
  # the instance's start `now` (that offset is what makes clock deductions
  # and timeouts replayable).
  defp persist_entry(%GameServerState{} = state, kind, player_id, payload, now) do
    Persister.action_applied(
      state.game_id,
      state.action_count,
      kind,
      player_id,
      payload,
      now - (state.clock_base || now)
    )
  end

  defp persist_finish(%GameServerState{} = state) do
    if GameKit.finished?(state.instance) do
      case GameKit.outcome(state.instance) do
        {:finished, winners} -> Persister.game_finished(state.game_id, winners)
        _ -> :ok
      end
    end
  end

  defp players_json(%GameServerState{} = state) do
    Enum.map(state.seat_order, fn id ->
      conn = state.connections[id]
      %{"id" => id, "name" => conn.name, "token" => conn.token, "guest_id" => conn.guest_id}
    end)
  end

  # A rematch is a new room with the same setup (fresh seed) and the same
  # players in the same seats: ids, names and seat tokens carry over, so the
  # link each player is already holding works in the new room.
  defp spawn_rematch(rematch_id, %GameServerState{} = state) do
    case Oskol.Game.GameSupervisor.start_game(rematch_id, state.slug) do
      {:ok, _pid} ->
        {:ok, _} = configure(rematch_id, %{state.setup | seed: nil})

        Enum.each(state.seat_order, fn id ->
          conn = state.connections[id]

          {:ok, ^id, _} =
            GenServer.call(
              via_tuple(rematch_id),
              {:seed_seat, id, conn.name, conn.token, conn.guest_id}
            )
        end)

        {:ok, _} = start_game(rematch_id)

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

  # ---------- Rehydration ----------

  # Rebuild the room from its persisted row: setup from config, seats (ids,
  # names, tokens) verbatim so every player's link still works, and — if the
  # game had started — the instance replayed from seed + action log.
  defp restore_state(%GameServerState{} = state, game, actions) do
    with {:ok, setup} <- restore_setup(state, game.config) do
      {connections, seat_order} = restore_seats(game.players)

      state =
        %GameServerState{state | setup: setup, connections: connections, seat_order: seat_order}
        |> GameServerState.update_lobby_status()
        |> GameServerState.touch()

      if game.seed == nil or game.status == "waiting" do
        {:ok, state}
      else
        replay(state, game, actions)
      end
    end
  end

  defp restore_setup(%GameServerState{} = state, config) do
    case GameServerState.validate_setup(state, %{
           format: config["format"],
           selections: config["selections"] || %{},
           clock: config["clock"] || "none",
           seed: config["seed"]
         }) do
      {:ok, setup} -> {:ok, setup}
      {:error, reason} -> {:error, {:bad_config, reason}}
    end
  end

  defp restore_seats(players) do
    Enum.reduce(players, {%{}, []}, fn player, {connections, order} ->
      connection = %{
        name: player["name"],
        token: player["token"],
        # Rows written before guests existed have no key here: nil is fine.
        guest_id: player["guest_id"],
        pid: nil,
        client: nil,
        connected: false,
        monitor_ref: nil
      }

      {Map.put(connections, player["id"], connection), order ++ [player["id"]]}
    end)
  end

  # Replay the log through the exact calls that produced it, with the whole
  # recorded timeline shifted so its last entry lands at the current
  # monotonic time: clock arithmetic only ever compares `now`s, so the
  # clocks come back as they stood after the last step, the downtime charges
  # nobody, and whoever is on the clock starts being charged again now.
  defp replay(%GameServerState{} = state, game, actions) do
    setup = state.setup
    control = setup.control || GameKit.clock_control(setup.clock)
    last_at = if actions == [], do: 0, else: List.last(actions).at_ms
    base = GameKit.now() - last_at

    with {:ok, instance} <-
           GameKit.start(
             state.slug,
             setup.format,
             GameServerState.seats(state),
             game.seed,
             control,
             base,
             Map.to_list(setup.selections)
           ),
         {:ok, instance} <- replay_actions(instance, actions, base) do
      new_state =
        %GameServerState{
          state
          | instance: instance,
            seed: game.seed,
            clock_base: base,
            action_count: length(actions)
        }
        |> schedule_clock_tick()

      {:ok, new_state}
    end
  end

  defp replay_actions(instance, actions, base) do
    Enum.reduce_while(actions, {:ok, instance}, fn entry, {:ok, instance} ->
      case replay_entry(instance, entry, base) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:replay_failed, entry.index, reason}}}
      end
    end)
  end

  defp replay_entry(instance, %{kind: "action"} = entry, base) do
    case GameKit.apply(instance, entry.player_id, entry.payload, base + entry.at_ms) do
      {:ok, next, _events} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_entry(instance, %{kind: "expire"} = entry, base) do
    case GameKit.expire(instance, base + entry.at_ms) do
      {:ok, next, _events} -> {:ok, next}
      :none -> {:ok, instance}
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
