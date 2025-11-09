defmodule Oskol.GameSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new game server for the given game_id.
  Returns {:ok, pid} if successful, or {:error, reason} if it fails.
  """
  def start_game(game_id) do
    spec = {Oskol.GameServer, game_id}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Finds an existing game server by game_id.
  Returns {:ok, pid} if found, or :error if not found.
  """
  def find_game(game_id) do
    case Registry.lookup(Oskol.GameRegistry, game_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Finds or starts a game server for the given game_id.
  Always returns {:ok, pid}.
  """
  def find_or_start_game(game_id) do
    case find_game(game_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case start_game(game_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end
end
