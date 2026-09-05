defmodule Oskol.Game do
  @moduledoc """
  Facade for game rooms. Rooms are generic over every registered game.
  """

  alias Oskol.Game.{GameServer, GameSupervisor}

  defdelegate start_game(game_id, slug), to: GameSupervisor
  defdelegate find_game(game_id), to: GameSupervisor
  defdelegate find_or_start_game(game_id, slug), to: GameSupervisor

  def lookup_game(game_id) do
    case GameSupervisor.find_game(game_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end

  @doc """
  Resolve a game code to the slug of its live room, so a bare code can be
  turned into the game's normal invite link. Says only whether a live room
  answers to the code — nothing else about it.
  """
  def lookup_slug(game_id) do
    with {:ok, _pid} <- lookup_game(game_id) do
      {:ok, GameServer.get_state(game_id).slug}
    end
  catch
    # The room died between the lookup and the call: same answer as no room.
    :exit, _ -> :not_found
  end

  @id_space 1_000_000
  @id_attempts 50

  @doc "A game code: 6 crypto-random digits."
  def generate_game_id do
    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(@id_space)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  @doc """
  Mint a fresh code and start a room for `slug` under it. The registry's
  unique keys make the claim atomic: a collision with a live room comes back
  as `already_started` and we mint again. `generate` is injectable for tests.
  """
  def create_game(slug, generate \\ &generate_game_id/0, attempts \\ @id_attempts)

  def create_game(_slug, _generate, 0), do: {:error, :no_free_id}

  def create_game(slug, generate, attempts) do
    game_id = generate.()

    case GameSupervisor.start_game(game_id, slug) do
      {:ok, _pid} -> {:ok, game_id}
      {:error, {:already_started, _pid}} -> create_game(slug, generate, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate attach(game_id, token, player_pid), to: GameServer
  defdelegate claim_seat(game_id, player_id, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate configure(game_id, attrs), to: GameServer
  defdelegate request_rematch(game_id, player_id), to: GameServer
  defdelegate player_action_async(game_id, player_id, action), to: GameServer
  defdelegate player_action(game_id, player_id, action), to: GameServer

  def start_game_session(game_id), do: GameServer.start_game(game_id)
end
