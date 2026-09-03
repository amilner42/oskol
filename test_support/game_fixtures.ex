defmodule Oskol.GameFixtures do
  @moduledoc "Helpers to spin up game rooms in tests. Backgammon is the reference game."

  alias Oskol.Game
  alias Oskol.GameKit

  def unique_game_id(prefix \\ "t") do
    prefix <> "-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc "A backgammon room with two seated players who agreed on a format, not yet started."
  def lobby(format \\ "single") do
    game_id = unique_game_id()
    {:ok, _} = Game.start_game(game_id, "backgammon")
    {:ok, p1, _} = Game.join_game(game_id, "Alice", nil)
    {:ok, p2, _} = Game.join_game(game_id, "Bob", nil)
    {:ok, _} = Game.select_format(game_id, p1, format)
    {:ok, _} = Game.select_format(game_id, p2, format)
    %{game_id: game_id, p1: p1, p2: p2}
  end

  @doc """
  A started backgammon game with a fixed seed. `mover` is the player to move
  (the opening roll decides), `waiting` the other one.
  """
  def started(seed \\ 42, format \\ "single") do
    fixture = lobby(format)
    {:ok, state} = Oskol.Game.GameServer.start_game(fixture.game_id, seed)
    mover = mover(state.instance, [fixture.p1, fixture.p2])
    waiting = if mover == fixture.p1, do: fixture.p2, else: fixture.p1
    fixture |> Map.put(:state, state) |> Map.put(:mover, mover) |> Map.put(:waiting, waiting)
  end

  @doc "Whoever holds a `move` schema."
  def mover(instance, players) do
    Enum.find(players, fn p ->
      Enum.any?(GameKit.player_update(instance, p)["legal"], &(&1["name"] == "move"))
    end)
  end

  @doc "The first legal move for a player as an action map, or nil."
  def legal_move(instance, player_id) do
    case Enum.find(GameKit.player_update(instance, player_id)["legal"], &(&1["name"] == "move")) do
      nil -> nil
      schema -> Oskol.Bots.action(schema)
    end
  end

  def move(game_id, player_id, action) do
    Game.player_action(game_id, player_id, action)
  end

  def simple(name), do: %{"name" => name, "params" => %{}}
end
