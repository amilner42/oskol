defmodule Oskol.Gleam.Caps.Rooms do
  @moduledoc """
  Real IO for src/oskol/caps/rooms.gleam. Keep field order in lockstep.

  The closures run in the process that built them: it is the one that
  follows a room's broadcasts, and `player_pid` is the one whose life the
  seat is tied to. A stateless request passes none, so the seat it takes has
  no live connection until the browser opens the link the response hands
  out and the game channel attaches to it.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Game
  alias Oskol.Game.GameServer
  alias Oskol.Game.GameServerState
  alias Oskol.Game.GameSupervisor
  alias Oskol.Game.Rehydrator

  # Reasons whose Gleam constructor is the very same atom
  # (`GameFull` -> `:game_full`), so they pass straight through.
  @known ~w(game_full name_taken invalid_name unknown_format unknown_clock
            unknown_setting unknown_choice game_already_started seat_connected
            seat_owned no_seat already_seated player_not_found game_not_started
            game_not_finished not_enough_players unknown_game no_free_id)a

  def build(opts \\ []) do
    player_pid = Keyword.get(opts, :player_pid)

    {:rooms_caps, fn game_id -> GameSupervisor.find_game(game_id) |> found() end,
     fn game_id -> Rehydrator.resume(game_id) |> found() end, &table/1,
     fn game_id -> opt(GameServer.get_state(game_id).slug) end,
     fn game_id, slug ->
       case GameSupervisor.start_game(game_id, slug) do
         {:ok, _pid} -> {:ok, nil}
         {:error, {:already_started, _pid}} -> {:error, :already_started}
         {:error, reason} -> {:error, {:spawn_failed, room_error(reason)}}
       end
     end,
     fn game_id ->
       Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
       nil
     end,
     fn game_id, {:setup, format, clock} ->
       attrs = %{format: format, clock: clock}

       case Game.configure(game_id, attrs) do
         {:ok, _state} -> {:ok, nil}
         {:error, reason} -> {:error, room_error(reason)}
       end
     end,
     fn game_id, name, guest_id, user_id ->
       case Game.join_game(
              game_id,
              name,
              player_pid,
              unopt(guest_id),
              unopt(user_id),
              Oskol.Auth.username(unopt(user_id))
            ) do
         {:ok, player_id, state} ->
           {:ok, {:seat, player_id, state.instance != nil}}

         {:error, reason} ->
           {:error, room_error(reason)}
       end
     end,
     fn game_id, player_id, guest_id, user_id ->
       # Claiming attaches, and attaching needs a process to watch. A
       # stateless caller watches itself: the seat is live for the length of
       # the request and away again after it, until the browser this call
       # answers opens the room. The seat is that browser's guest from here,
       # and its account's if it has one.
       case Game.claim_seat(
              game_id,
              player_id,
              player_pid || self(),
              unopt(guest_id),
              unopt(user_id),
              Oskol.Auth.username(unopt(user_id))
            ) do
         {:ok, ^player_id, state} ->
           {:ok, {:seat, player_id, state.instance != nil}}

         {:error, reason} ->
           {:error, room_error(reason)}
       end
     end, &seated_game/3, &game/1}
  end

  # The running game at a room, for anyone: a record and a replay are what
  # both players and any spectator already saw. It attaches nothing.
  defp game(game_id) do
    state = GameServer.get_state(game_id)

    if state.instance == nil, do: {:error, :game_not_started}, else: {:ok, state.instance}
  catch
    :exit, _ -> {:error, :game_not_started}
  end

  # The running game behind the seat this caller holds, read and handed back
  # as the opaque Gleam instance it is, with the player id of that seat. The
  # holder rule decides which seat, so an account finds its own from any
  # browser it is signed in on. It attaches nothing: a record read is not a
  # connection. A room that died between the lookup and this call answers
  # like a seat that is not there.
  defp seated_game(game_id, guest_id, user_id) do
    state = GameServer.get_state(game_id)
    session = GameServerState.session(unopt(guest_id), unopt(user_id))

    case GameServerState.find_player_id_for(state, session) do
      nil -> {:error, :no_seat}
      _player_id when state.instance == nil -> {:error, :game_not_started}
      player_id -> {:ok, {player_id, state.instance}}
    end
  catch
    :exit, _ -> {:error, :no_seat}
  end

  # The table as an invite link finds it. A room that died between the
  # lookup and this call answers like no room at all.
  defp table(game_id) do
    state = GameServer.get_state(game_id)

    {:some,
     {:table, GameServerState.full?(state), opt(inviter_name(state)),
      GameServerState.summary(state), GameServerState.disconnected_seats(state)}}
  catch
    :exit, _ -> :none
  end

  # Somebody who is at the table right now, if anybody is.
  defp inviter_name(state) do
    case Enum.find(state.connections, fn {_id, conn} -> conn.connected end) do
      {_id, conn} -> GameServerState.display_name(conn)
      nil -> nil
    end
  end

  # A live room crosses as the Gleam `rooms/room.Room` wrapper: opaque
  # there, a pid here.
  defp found({:ok, pid}), do: {:some, {:room, pid}}
  defp found(_), do: :none

  @doc "The pid inside a Gleam `Room`."
  def process({:room, pid}), do: pid

  @doc "An Elixir room reason as the Gleam `rooms/errors.RoomError` for it."
  def room_error(reason) when reason in @known, do: reason
  def room_error(reason) when is_atom(reason), do: {:other, Atom.to_string(reason)}
  def room_error(reason) when is_binary(reason), do: {:other, reason}
  def room_error(reason), do: {:other, inspect(reason)}

  @doc "A Gleam `RoomError` back as the atom `Oskol.Game` has always returned."
  def reason({:other, text}), do: text
  def reason(atom) when is_atom(atom), do: atom
end
