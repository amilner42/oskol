defmodule Oskol.Game.GameServer do
  @moduledoc """
  One process per game room. Generic over every registered game: it owns the
  connections, the creator's setup, and an opaque game instance that it
  drives through `Oskol.GameKit`.

  The creator sets the room up (format, clock) and shares a link;
  the game starts the moment the table is full.
  """
  # Rooms hold their whole state in memory; the database holds the durable
  # picture (seed + action log, written behind by Oskol.Game.Persister). A
  # crashed or idle-stopped room is not restarted here: the next lookup
  # rehydrates it from the log (Oskol.Game.Rehydrator), so an idle stop is
  # graceful, not final.
  use GenServer, restart: :temporary
  require Logger

  alias Oskol.Game.Bot
  alias Oskol.Game.GameServerState
  alias Oskol.Game.Persister
  alias Oskol.GameKit
  alias Oskol.Gleam.Interop

  @timeout :timer.hours(1)

  # ---------- Client API ----------

  def start_link({game_id, slug}) do
    GenServer.start_link(__MODULE__, {game_id, slug}, name: via_tuple(game_id))
  end

  def start_link({game_id, slug, restore}) do
    GenServer.start_link(__MODULE__, {game_id, slug, restore}, name: via_tuple(game_id))
  end

  @doc """
  Take a free seat. `guest_id` is the visitor's guest-cookie id, and it is
  what holds the seat from here: the channel attaches on it, and nothing in
  a URL opens it. The display name is display only. A seat taken with no
  guest id (tooling, a seeded room) is held by nobody, and the first
  browser to ask for it from the invite link takes it.

  `user_id` is the account signed in on that browser, if any: a seat taken
  while signed in is that account's from the start, and no room code ever
  opens it again.

  One browser holds at most one seat at a table, because one guest id can
  only name one of them: a guest already seated here is
  `{:error, :already_seated}` rather than a second seat it could never
  reach. An account is the same, whatever browser it asks from: one seat
  per table. Two players are two browsers.
  """
  def join_game(
        game_id,
        player_name,
        player_pid \\ nil,
        guest_id \\ nil,
        user_id \\ nil,
        username \\ nil
      )

  def join_game(game_id, player_name, player_pid, guest_id, user_id, username) do
    GenServer.call(
      via_tuple(game_id),
      {:join_game, player_name, player_pid, guest_id, user_id, username}
    )
  end

  @doc """
  Sit a bot down at a free seat, filling the table and starting the game.

  It holds no guest and no account, so `src/oskol/rooms/seat.gleam` says
  nobody holds that seat and nothing claims it, and it is never away, so the
  invite link has nothing to offer. There is no process behind it either:
  what drives it is `Oskol.Game.Bot`, off this one.
  """
  def join_bot(game_id, player_name) do
    GenServer.call(via_tuple(game_id), {:join_bot, player_name})
  end

  @doc """
  Attach a connection to the seat a guest holds.

  Which seat, if any, is the holder rule (`src/oskol/rooms/seat.gleam`): an
  owned seat answers to its account, from any browser signed into it and
  from nothing else; an unowned one answers to the guest that took it.

  This is the only way to reach a seat with an already-connected player: a
  second connection from the same holder is the same person, so the latest
  one wins and the previous socket is dropped. A caller who holds no seat
  here is `{:error, :no_seat}` — it never falls back to any other seat.

  `client` identifies the browser behind the connection (the socket's
  transport, which outlives any one channel), and it is what tells a
  reconnect from a takeover: see `src/oskol/rooms/seat.gleam`. Callers with
  nothing better to offer pass the connection itself.
  """
  def attach(game_id, guest_id, player_pid, client \\ nil, user_id \\ nil) do
    GenServer.call(
      via_tuple(game_id),
      {:attach, GameServerState.session(guest_id, user_id), player_pid, client || player_pid}
    )
  end

  @doc """
  Reclaim a seat whose player is away, from the invite link. The seat passes
  to `guest_id` (and to `user_id`, when the claiming browser is signed in),
  so it is that browser's from here and whoever sat there before no longer
  holds it. Returns `{:ok, player_id, state}`. A seat whose player is
  connected is `{:error, :seat_connected}`; a seat an account owns is
  `{:error, :seat_owned}`, whoever asks — ownership is not a code away.
  """
  def claim_seat(
        game_id,
        player_id,
        player_pid,
        guest_id \\ nil,
        user_id \\ nil,
        username \\ nil
      )

  def claim_seat(game_id, player_id, player_pid, guest_id, user_id, username) do
    GenServer.call(
      via_tuple(game_id),
      {:claim_seat, player_id, player_pid, guest_id, user_id, username}
    )
  end

  def get_state(game_id), do: GenServer.call(via_tuple(game_id), :get_state)

  @doc """
  Set the room up before it starts: `%{format: id,
  clock: preset_id}`, plus `seed:` and `control:` for tests and tooling.
  """
  def configure(game_id, attrs) when is_map(attrs) do
    GenServer.call(via_tuple(game_id), {:configure, attrs, []})
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

  @doc """
  A bot seat's action, sent to the very room process that started its think
  (a pid, never the name: a room rehydrated under the same name is a
  different room, with a think of its own), and applied only if nothing has
  happened there since step `at`. `{:error, :moved_on}` otherwise -- a
  resignation, a timeout or the other player got there first, and the rest
  of what the bot decided was decided on a board that no longer exists.
  """
  def bot_action(room, player_id, action, at) when is_pid(room) and is_map(action) do
    GenServer.call(room, {:bot_action, player_id, action, at})
  end

  @doc "The state of the room process `room`, by pid. See `bot_action/4`."
  def state_of(room) when is_pid(room), do: GenServer.call(room, :get_state)

  @doc """
  A browser signed in: every seat here it held as a guest, and that no
  account owns yet, is that account's now and moves to the browser's fresh
  guest id with it.

  The same change as the row's (`Oskol.Auth.stamp_seats/3`, the same
  Gleam rule `seat.stamp`), in the live room's memory, so the two agree
  without the room writing anything back. It is idempotent. Returns how
  many seats it made the account's. At a table where
  this account already owns a seat the other one is not stamped (one
  person, one seat per table), but it still moves to the fresh guest id, so
  the browser keeps it as a guest seat.
  """
  def stamp(game_id, old_guest_id, new_guest_id, user_id, username \\ nil)

  def stamp(game_id, old_guest_id, new_guest_id, user_id, username) do
    GenServer.call(
      via_tuple(game_id),
      {:stamp, old_guest_id, new_guest_id, user_id, username}
    )
  catch
    # The room stopped before or during this call. Its next rehydrate reads
    # the stamped row.
    :exit, _ -> 0
  end

  @doc """
  An account renamed itself: every seat it holds here plays under the new
  name from now on. Nothing is written -- a seat points at the account --
  so this is the live room catching up with the one row that changed.
  """
  def rename(game_id, user_id, username) do
    GenServer.call(via_tuple(game_id), {:rename, user_id, username})
  catch
    :exit, _ -> :ok
  end

  def request_rematch(game_id, player_id) do
    GenServer.call(via_tuple(game_id), {:request_rematch, player_id})
  end

  @doc """
  Close a lobby nobody joined: the room writes itself off and stops.

  Only a seat here may (the holder rule, as every other door asks it), and
  only while the room has no game in it. A room that has started is not
  closed from outside: a game in play is left by resigning, and unlimited
  play is ended between games by the `close` action, which the engine
  decides on and the log records like any other step.

  This is the authoritative check. The handler has already refused whoever
  the row says holds no seat here, so that a stranger's press never rebuilds
  a cold room from its log; the room's own memory is the copy that can have
  moved since that row was read. Checking and writing here are one call, and
  the room is the only writer of its own row, so nothing can start the game
  between the two.

  The write itself is the ordinary write-behind, one `UPDATE` like every
  other room write: no transaction and no row lock go anywhere near the
  single process that writes for every room. What waits for it is the
  request (`Oskol.Game.Persister.flush/0`), because the page it answers
  reads the list this row leaves.
  """
  def close(game_id, guest_id \\ nil, user_id \\ nil)

  def close(game_id, guest_id, user_id) do
    GenServer.call(via_tuple(game_id), {:close, GameServerState.session(guest_id, user_id)})
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
        # A deploy or an idle stop can land in the middle of a bot's turn, and
        # the think that was running went with the old process. Start it again
        # once the room is up, not in `init`, so nothing waits on the engine
        # for a room to answer its first call.
        {:ok, state, {:continue, :bots}}

      {:error, reason} ->
        Logger.error("Could not rehydrate game #{game_id}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_call({:configure, attrs, opts}, _from, %GameServerState{} = state) do
    cond do
      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        case GameServerState.validate_setup(state, attrs, opts) do
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
        {:join_game, player_name, player_pid, guest_id, user_id, username},
        _from,
        %GameServerState{} = state
      ) do
    session = GameServerState.session(guest_id, user_id)

    cond do
      GameServerState.full?(state) ->
        {:reply, {:error, :game_full}, state, @timeout}

      GameServerState.name_taken?(state, player_name) ->
        {:reply, {:error, :name_taken}, state, @timeout}

      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      GameServerState.find_player_id_for(state, session) != nil ->
        {:reply, {:error, :already_seated}, state, @timeout}

      true ->
        monitor_ref = if player_pid, do: Process.monitor(player_pid), else: nil
        player_id = generate_player_id()

        connection = %{
          name: player_name,
          username: username,
          guest_id: guest_id,
          user_id: user_id,
          bot: false,
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

        new_state = Bot.think(new_state)
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call({:join_bot, player_name}, _from, %GameServerState{} = state) do
    cond do
      GameServerState.full?(state) ->
        {:reply, {:error, :game_full}, state, @timeout}

      GameServerState.name_taken?(state, player_name) ->
        {:reply, {:error, :name_taken}, state, @timeout}

      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        player_id = generate_player_id()

        connection = %{
          name: player_name,
          username: nil,
          guest_id: nil,
          user_id: nil,
          bot: true,
          pid: nil,
          client: nil,
          # A bot is always at the table. Nothing watches a process for it,
          # so nothing can mark it away, and the invite link therefore never
          # offers its seat to a visitor with the code.
          connected: true,
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

        new_state =
          if GameServerState.full?(new_state) do
            case do_start(new_state, nil, nil) do
              {:ok, started} -> started
              {:error, _} -> new_state
            end
          else
            new_state
          end

        new_state = Bot.think(new_state)
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call({:attach, session, player_pid, client}, _from, %GameServerState{} = state) do
    case GameServerState.find_player_id_for(state, session) do
      nil ->
        {:reply, {:error, :no_seat}, state, @timeout}

      player_id ->
        new_state = do_attach(state, player_id, player_pid, client)

        # The attaching client gets the state in its reply; everyone else
        # learns the seat is live again.
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  def handle_call(
        {:claim_seat, player_id, player_pid, guest_id, user_id, username},
        _from,
        %GameServerState{} = state
      ) do
    conn = state.connections[player_id]
    session = GameServerState.session(guest_id, user_id)
    # The seat, if any, this caller is already sitting at here.
    held = GameServerState.find_player_id_for(state, session)

    cond do
      conn == nil ->
        {:reply, {:error, :player_not_found}, state, @timeout}

      not :oskol@rooms@seat.claimable(GameServerState.seat_record(player_id, conn)) ->
        # An owned seat is its account's for good, and a bot seat is nobody's
        # to stand in for. Neither is a claim away: the one rule is
        # `src/oskol/rooms/seat.gleam`'s `claimable`, and the two reasons are
        # only so the sentence a caller is shown is the true one.
        if Map.get(conn, :bot, false),
          do: {:reply, {:error, :seat_is_bot}, state, @timeout},
          else: {:reply, {:error, :seat_owned}, state, @timeout}

      conn.connected ->
        # A seat with a live player is locked: only the guest holding it
        # gets in, and they are already here.
        {:reply, {:error, :seat_connected}, state, @timeout}

      held != nil and held != player_id ->
        # This browser already sits at another seat in this room. Taking a
        # second would write its guest onto both, and a guest id names one
        # seat: it would hold whichever comes first in seat order and be
        # unable to reach the other. Two seats is two browsers. (Claiming
        # back the seat it already holds is the reconnect case, and passes.)
        {:reply, {:error, :already_seated}, state, @timeout}

      true ->
        # The seat changes hands: the claiming browser holds it now, so the
        # guest who held it before cannot walk back in behind their back.
        # A signed-in browser takes it as its account's, for good.
        claimed = %{
          conn
          | guest_id: guest_id,
            user_id: user_id,
            username: username
        }

        state = %GameServerState{
          state
          | connections: Map.put(state.connections, player_id, claimed)
        }

        new_state = do_attach(state, player_id, player_pid, player_pid)

        # Who holds the seat must be on disk before it is the only way in.
        Persister.players_updated(new_state.game_id, players_json(new_state))
        broadcast(new_state, [])
        {:reply, {:ok, player_id, new_state}, new_state, @timeout}
    end
  end

  # A rematch is the same players in the same seats: the new room is seeded
  # with the old ids, names and guests, so each player's browser holds the
  # same seat in it.
  def handle_call(
        {:seed_seat, player_id, name, guest_id, user_id, username, bot},
        _from,
        %GameServerState{} = state
      ) do
    connection = %{
      name: name,
      username: username,
      guest_id: guest_id,
      user_id: user_id,
      bot: bot,
      pid: nil,
      client: nil,
      # A person has to open the new room before their seat is live; the bot
      # is simply there, as it was in the room this one is a rematch of.
      connected: bot,
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
        new_state = Bot.think(new_state)
        broadcast(new_state, [])
        {:reply, {:ok, new_state}, new_state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:player_action, player_id, action}, _from, %GameServerState{} = state) do
    case apply_action(state, player_id, action) do
      {:ok, new_state, events} ->
        new_state = Bot.think(new_state)
        broadcast(new_state, events, player_id)
        grade_turn(new_state, events)
        {:reply, {:ok, new_state, events}, new_state, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:bot_action, player_id, action, at}, from, %GameServerState{} = state) do
    if state.action_count == at do
      handle_call({:player_action, player_id, action}, from, state)
    else
      {:reply, {:error, :moved_on}, state, @timeout}
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
        # A bot has nothing to press. Counting its seat as ready is what makes
        # one REMATCH enough at a table where the other player is Sage.
        ready =
          state.rematch_ready
          |> MapSet.put(player_id)
          |> MapSet.union(MapSet.new(GameServerState.bot_seats(state)))

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

  # A sign-in, reaching the room after the row was written. Only seats this
  # guest holds and nobody owns, and only when the account has no seat here
  # already.
  def handle_call(
        {:stamp, old_guest_id, new_guest_id, user_id, username},
        _from,
        %GameServerState{} = state
      ) do
    {stamped, count} =
      stamp_seats(state, old_guest_id, new_guest_id, user_id, username)

    {:reply, count, stamped, @timeout}
  end

  def handle_call({:rename, user_id, username}, _from, %GameServerState{} = state) do
    connections =
      Map.new(state.connections, fn {id, conn} ->
        if conn.user_id == user_id, do: {id, %{conn | username: username}}, else: {id, conn}
      end)

    new_state = %GameServerState{state | connections: connections}
    broadcast(new_state, [])
    {:reply, :ok, new_state, @timeout}
  end

  def handle_call({:close, session}, _from, %GameServerState{} = state) do
    cond do
      GameServerState.find_player_id_for(state, session) == nil ->
        # A stranger, a spectator, and the bot's seat (which nobody holds)
        # all land here: the one holder rule, and nothing else, opens a room.
        {:reply, {:error, :no_seat}, state, @timeout}

      GameServerState.started?(state) ->
        {:reply, {:error, :game_already_started}, state, @timeout}

      true ->
        Logger.info("Lobby #{state.game_id} closed by its player")
        Persister.game_closed(state.game_id)
        # Any other tab of this browser is sitting in the same lobby; tell
        # it the room is gone rather than leaving it waiting on a room that
        # no longer exists.
        Phoenix.PubSub.broadcast(Oskol.PubSub, topic(state.game_id), :room_closed)
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call(:get_state, _from, %GameServerState{} = state) do
    {:reply, state, state, @timeout}
  end

  @impl true
  def handle_cast({:player_action, player_id, action}, %GameServerState{} = state) do
    case apply_action(state, player_id, action) do
      {:ok, new_state, events} ->
        new_state = Bot.think(new_state)
        broadcast(new_state, events, player_id)
        grade_turn(new_state, events)
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
  def handle_continue(:bots, %GameServerState{} = state) do
    state = Bot.think(state)
    broadcast(state, [])
    {:noreply, state, @timeout}
  end

  # A bot seat's think, come back with what it made of the turn.
  @impl true
  def handle_info({ref, outcome}, %GameServerState{} = state) when is_reference(ref) do
    case Bot.finished(state, ref, outcome) do
      {:ok, state} ->
        Process.demonitor(ref, [:flush])
        # The seat is free to think again, and usually will not: the turn it
        # just played is somebody else's now. What this catches is the turn
        # that moved on while it was thinking.
        state = Bot.think(state)
        broadcast(state, [])
        {:noreply, state, @timeout}

      :none ->
        {:noreply, state, @timeout}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %GameServerState{} = state) do
    case Bot.finished(state, ref, :crashed) do
      {:ok, state} ->
        state = Bot.think(state)
        broadcast(state, [])
        {:noreply, state, @timeout}

      :none ->
        handle_player_down(ref, state)
    end
  end

  # Clock-driven turns are not activity: a table both players walked away
  # from must still go idle, even if a timeout keeps acting for them.
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

          persist_entry(state, "expire", nil, nil, now, instance)
          persist_finish(new_state)
          request_review(new_state, events)
          new_state = Bot.think(new_state)
          broadcast(new_state, events)
          grade_turn(new_state, events)
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

  defp handle_player_down(ref, %GameServerState{} = state) do
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

  # ---------- Private ----------

  defp do_start(%GameServerState{} = state, seed, control) do
    setup = state.setup
    now = GameKit.now()

    with false <- GameServerState.started?(state),
         true <- map_size(state.connections) >= GameServerState.min_players(state),
         seed <- seed || setup.seed || :rand.uniform(2_147_483_647),
         control <-
           control || setup.control ||
             GameKit.clock_control(state.slug, setup.format, setup.clock),
         {:ok, instance} <-
           GameKit.start(
             state.slug,
             setup.format,
             GameServerState.seats(state),
             seed,
             control,
             now
           ) do
      new_state =
        %GameServerState{state | instance: instance, seed: seed, clock_base: now, action_count: 0}
        |> GameServerState.touch()
        |> schedule_clock_tick()

      Persister.game_started(
        state.game_id,
        seed,
        setup,
        players_json(new_state),
        GameKit.summary(instance, now)
      )

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
  # in a second tab): the old monitor is dropped so its exit cannot mark a
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

            persist_entry(state, "action", player_id, action, now, instance)
            persist_finish(new_state)
            request_review(new_state, events)
            {:ok, new_state, events}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Append one log entry at the room's current index, with its offset from
  # the instance's start `now` (that offset is what makes clock deductions
  # and timeouts replayable), and where the game stands after it.
  defp persist_entry(%GameServerState{} = state, kind, player_id, payload, now, instance) do
    Persister.action_applied(
      state.game_id,
      state.action_count,
      kind,
      player_id,
      payload,
      now - (state.clock_base || now),
      GameKit.summary(instance, now)
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

  # A game that just ended may be owed a post-game review. Whether it is,
  # is Gleam's call; the review itself runs in Oskol.Reviews.Queue, never
  # here and never on the game channel. The queue reads the log only after
  # the persister has written what was cast above.
  defp request_review(%GameServerState{} = state, events) do
    if :oskol@handlers@reviews.game_ended(state.slug, events) do
      # Written down first, asked for second. The queue lives in memory, so
      # a restart between the two would lose the job and -- since a read
      # never queues engine work -- nothing would ever pick it up. The note
      # survives; `Oskol.Reviews.Queue` sweeps it on boot.
      Oskol.Game.Persister.analysis_owed(state.game_id)
      Oskol.Reviews.Queue.enqueue(state.game_id)
    end
  end

  # A turn the step just committed may be graded now, while the game goes on,
  # so the report is ready when it ends. Whether that step committed anything
  # is the game's own answer (`GameKit.committed/1`); the grading is
  # `Oskol.Reviews.Grader`, which answers nobody and writes to a table only
  # the end-of-game job reads.
  #
  # After the broadcast, never before: both players have their update first,
  # and nothing about a grade is ever part of it. Never on the step that ended
  # the game either -- the review job grades that turn itself, along with
  # every turn the grader missed. And only from a step the room actually took:
  # `replay_entry` rebuilds a room by stepping through its whole log, and a
  # rehydrate must not grade a match all over again.
  defp grade_turn(%GameServerState{} = state, events) do
    if :oskol@handlers@reviews.game_ended(state.slug, events) do
      :ok
    else
      case GameKit.committed(state.instance) do
        {:ok, payload} -> Oskol.Reviews.Grader.grade(state.game_id, payload)
        :none -> :ok
      end
    end
  end

  defp players_json(%GameServerState{} = state) do
    Enum.map(state.seat_order, fn id ->
      conn = state.connections[id]

      %{
        "id" => id,
        "name" => conn.name,
        "guest_id" => conn.guest_id,
        "user_id" => conn.user_id,
        # So a bot seat survives a rehydrate: a room rebuilt from its row has
        # to know which seat plays itself, or nobody would move.
        "bot" => Map.get(conn, :bot, false)
      }
    end)
  end

  # Hand this guest's unowned seats to the account it just signed into, and
  # move them to its fresh guest id. Memory only: the row was written first,
  # and writing it again from here could only race what the row already
  # says.
  #
  # At a table where the account already owns a seat the other seat is not
  # stamped, the same rule the write follows (one person, one seat per
  # table), but it still moves to the fresh guest id with the browser.
  defp stamp_seats(%GameServerState{} = state, old_guest_id, new_guest_id, user_id, username)
       when is_binary(old_guest_id) and is_binary(new_guest_id) and is_binary(user_id) do
    # The rule is Gleam's (`seat.stamp`), the same one the row followed.
    {seats, count} =
      :oskol@rooms@seat.stamp(
        GameServerState.seat_records(state),
        old_guest_id,
        new_guest_id,
        user_id
      )

    connections =
      Enum.reduce(seats, state.connections, fn {:seat, id, guest, user, _bot}, connections ->
        Map.update!(connections, id, fn conn ->
          owner = Interop.unopt(user)

          %{
            conn
            | guest_id: Interop.unopt(guest),
              user_id: owner,
              username: if(owner == user_id, do: username, else: conn.username)
          }
        end)
      end)

    {%GameServerState{state | connections: connections}, count}
  end

  defp stamp_seats(%GameServerState{} = state, _old, _new, _user, _username), do: {state, 0}

  # A rematch is a new room with the same setup (fresh seed) and the same
  # players in the same seats: ids, names, the guest holding each seat and
  # the account owning it carry over, so both browsers walk straight into
  # the new room and an owned seat is still owned there.
  defp spawn_rematch(rematch_id, %GameServerState{} = state) do
    case Oskol.Game.GameSupervisor.start_game(rematch_id, state.slug) do
      {:ok, _pid} ->
        # The setup was valid when the room was made; a clock retired since
        # still carries over, as it does on a rebuild.
        {:ok, _} =
          GenServer.call(
            via_tuple(rematch_id),
            {:configure, %{state.setup | seed: nil}, retired_clocks: true}
          )

        Enum.each(state.seat_order, fn id ->
          conn = state.connections[id]

          {:ok, ^id, _} =
            GenServer.call(
              via_tuple(rematch_id),
              {:seed_seat, id, conn.name, conn.guest_id, conn.user_id, conn.username,
               Map.get(conn, :bot, false)}
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
  # names, the guest holding each) verbatim so every player's browser still
  # holds its seat, and — if the game had started — the instance replayed
  # from seed + action log.
  defp restore_state(%GameServerState{} = state, game, actions) do
    with {:ok, setup} <- restore_setup(state, game.config) do
      {connections, seat_order} = restore_seats(game.players)

      state =
        %GameServerState{state | setup: setup, connections: connections, seat_order: seat_order}
        |> GameServerState.update_lobby_status()
        |> GameServerState.touch()

      if game.seed == nil or game.status == "waiting" do
        {:ok, refresh_holders(state)}
      else
        case replay(state, game, actions) do
          {:ok, replayed} -> {:ok, refresh_holders(replayed)}
          other -> other
        end
      end
    end
  end

  # Who holds each seat, read once more before the room goes live.
  #
  # A replay takes time, and a sign-in landing in the middle of it writes
  # the seats' holders (`Oskol.Auth.stamp_seats/3`) against a row we had
  # already read. Reading `players` again — one small query, no log — is
  # what keeps the room from coming up believing the seat still belongs to
  # the guest it did five seconds ago. Names, ids and seat order are the
  # replay's; only the holder is taken from the row.
  defp refresh_holders(%GameServerState{} = state) do
    holders =
      for player <- Oskol.Persistence.players(state.game_id),
          is_map(player),
          id = player["id"],
          is_binary(id),
          into: %{},
          do: {id, {player["guest_id"], player["user_id"]}}

    connections =
      Map.new(state.connections, fn {id, conn} ->
        case holders[id] do
          {guest_id, user_id} -> {id, %{conn | guest_id: guest_id, user_id: user_id}}
          nil -> {id, conn}
        end
      end)

    %GameServerState{state | connections: connections}
  rescue
    # The row is the same one we just rebuilt from; if reading it again
    # fails, what we have is still right for every room but a stamped one.
    _ -> state
  end

  defp restore_setup(%GameServerState{} = state, config) do
    case GameServerState.validate_setup(
           state,
           %{
             format: config["format"],
             clock: config["clock"] || "none",
             seed: config["seed"]
           },
           retired_clocks: true
         ) do
      {:ok, setup} -> {:ok, setup}
      {:error, reason} -> {:error, {:bad_config, reason}}
    end
  end

  defp restore_seats(players) do
    Enum.reduce(players, {%{}, []}, fn player, {connections, order} ->
      connection = %{
        name: player["name"],
        bot: player["bot"] == true,
        # Looked up once, on the way back: an owned seat plays under the
        # account's name as it is now.
        # Resolved by the caller before the room came up: a room does no IO.
        username: player["username"],
        # Rows written before guests existed have no key here: nil is fine,
        # and that seat is held by nobody until someone claims it from the
        # invite link. Rows written before seat tokens were dropped still
        # carry a "token" key; nothing reads it.
        guest_id: player["guest_id"],
        # The account that owns this seat, if one does. A row written before
        # accounts has no key here, and that seat is simply unowned.
        user_id: player["user_id"],
        pid: nil,
        client: nil,
        # Everyone is away until their browser comes back; the bot never was.
        connected: player["bot"] == true,
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
    control = setup.control || GameKit.clock_control(state.slug, setup.format, setup.clock)
    last_at = if actions == [], do: 0, else: List.last(actions).at_ms
    base = GameKit.now() - last_at

    with {:ok, instance} <-
           GameKit.start(
             state.slug,
             setup.format,
             GameServerState.seats(state),
             game.seed,
             control,
             base
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

      # A row from before the snapshot existed says nothing about where the
      # game stands; the room that just replayed it knows, so write it. Not
      # activity: the row's updated_at stays where the last step left it.
      Persister.state_mirrored(state.game_id, GameKit.summary(instance))
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

  # Every change to the room goes to every connection on it, each of which
  # projects it for its own seat (`OskolWeb.GameChannel`). `by` is the seat
  # whose action made the change, nil when the room itself did (a start, a
  # clock, a seat coming or going): a channel pushes its own seat's actions at
  # once and coalesces a burst of somebody else's -- a mover staging checkers
  # quickly reaches the opponent as their ghosts, not as a flood. `id` names
  # this one broadcast, so a subscriber that hears it twice can tell.
  defp broadcast(%GameServerState{} = state, events, by \\ nil) do
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      topic(state.game_id),
      {:game_state_updated, state, events, %{by: by, id: make_ref()}}
    )
  end
end
