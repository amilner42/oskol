defmodule Oskol.Game.GameSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a room for the given game slug."
  def start_game(game_id, slug) do
    if Oskol.GameKit.exists?(slug) do
      DynamicSupervisor.start_child(__MODULE__, {Oskol.Game.GameServer, {game_id, slug}})
    else
      {:error, :unknown_game}
    end
  end

  def find_game(game_id) do
    case Registry.lookup(Oskol.GameRegistry, game_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def find_or_start_game(game_id, slug) do
    case find_game(game_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case start_game(game_id, slug) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
