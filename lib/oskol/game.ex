defmodule Oskol.Game do
  @moduledoc """
  Facade for game rooms. Rooms are generic over every registered game.

  The decisions here — mint a code until one is free, look a room up and
  rehydrate it if no process answers — live in the Gleam handler
  `oskol/handlers/rooms`; this module is the Elixir door onto it and keeps
  the process plumbing (`Oskol.Game.GameServer`) it drives.
  """

  alias Oskol.Game.{GameServer, GameSupervisor}
  alias Oskol.Gleam.Caps
  alias Oskol.Gleam.CtxBuilder

  defdelegate start_game(game_id, slug), to: GameSupervisor
  defdelegate find_game(game_id), to: GameSupervisor
  defdelegate find_or_start_game(game_id, slug), to: GameSupervisor

  @doc """
  The live room for a code. When no process answers but the database still
  has the game, the room is rehydrated (seed + action log replayed, seats
  and tokens restored) before answering — this is how games survive deploys
  and idle shutdowns.
  """
  def lookup_game(game_id) do
    case :oskol@handlers@rooms.lookup(CtxBuilder.build(), game_id) do
      {:some, room} -> {:ok, Caps.Rooms.process(room)}
      :none -> :not_found
    end
  end

  @doc """
  Resolve a game code to the slug of its live room, so a bare code can be
  turned into the game's normal invite link. Says only whether a live room
  answers to the code — nothing else about it.
  """
  def lookup_slug(game_id) do
    case :oskol@handlers@rooms.lookup_slug(CtxBuilder.build(), game_id) do
      {:some, slug} -> {:ok, slug}
      :none -> :not_found
    end
  catch
    # The room died between the lookup and the call: same answer as no room.
    :exit, _ -> :not_found
  end

  @id_space 1_000_000

  @doc "A game code: 6 crypto-random digits."
  def generate_game_id do
    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(@id_space)
    |> :oskol@rooms@code.from_random()
  end

  @doc """
  Mint a fresh code and start a room for `slug` under it. The registry's
  unique keys make the claim atomic: a collision with a live room comes back
  as `already_started` and we mint again. `generate` is injectable for tests.
  """
  def create_game(
        slug,
        generate \\ &generate_game_id/0,
        attempts \\ :oskol@handlers@rooms.attempts()
      ) do
    ctx = CtxBuilder.build(generate: generate)

    case :oskol@handlers@rooms.create_room(ctx, slug, attempts) do
      {:ok, game_id} -> {:ok, game_id}
      {:error, reason} -> {:error, Caps.Rooms.reason(reason)}
    end
  end

  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate join_game(game_id, player_name, player_pid, guest_id), to: GameServer
  defdelegate attach(game_id, token, player_pid), to: GameServer
  defdelegate claim_seat(game_id, player_id, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate configure(game_id, attrs), to: GameServer
  defdelegate request_rematch(game_id, player_id), to: GameServer
  defdelegate player_action_async(game_id, player_id, action), to: GameServer
  defdelegate player_action(game_id, player_id, action), to: GameServer

  def start_game_session(game_id), do: GameServer.start_game(game_id)
end
