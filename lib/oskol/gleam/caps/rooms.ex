defmodule Oskol.Gleam.Caps.Rooms do
  @moduledoc """
  Real IO for src/oskol/caps/rooms.gleam. Keep field order in lockstep.

  The closures run in the process that built them: it is the one that
  follows a room's broadcasts, and `player_pid` is the one that takes the
  seat, so a LiveView builds a context that seats the LiveView and a
  controller one that seats nobody (no process to monitor, no live socket).
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
            invalid_token player_not_found game_not_started game_not_finished
            not_enough_players unknown_game no_free_id)a

  def build(opts \\ []) do
    player_pid = Keyword.get(opts, :player_pid)

    {:rooms_caps, fn game_id -> GameSupervisor.find_game(game_id) |> found() end,
     fn game_id -> Rehydrator.resume(game_id) |> found() end,
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
     fn game_id, {:setup, format, selections, clock} ->
       attrs = %{format: format, selections: Map.new(selections), clock: clock}

       case Game.configure(game_id, attrs) do
         {:ok, _state} -> {:ok, nil}
         {:error, reason} -> {:error, room_error(reason)}
       end
     end,
     fn game_id, name, guest_id ->
       case Game.join_game(game_id, name, player_pid, unopt(guest_id)) do
         {:ok, player_id, state} ->
           {:ok,
            {:seat, player_id, GameServerState.token_for(state, player_id), state.instance != nil}}

         {:error, reason} ->
           {:error, room_error(reason)}
       end
     end}
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
