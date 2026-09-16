defmodule Oskol.GameFixtures do
  @moduledoc "Helpers to spin up game rooms in tests. Backgammon is the reference game."

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.GameKit

  def unique_game_id(prefix \\ "t") do
    prefix <> "-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc """
  A backgammon room set up by its creator (Alice), waiting for an opponent.
  Alice's seat is held by the guest `g1`, as a real browser's would be.
  Options: `clock:` preset id, `seed:`, `control:` raw clock control, and
  `slug:` for the platform tests that want a game without backgammon's
  twelve-second turn delay (a clock forfeit inside a test's patience).
  """
  def lobby(format \\ "single", opts \\ []) do
    game_id = unique_game_id()
    {:ok, _} = Game.start_game(game_id, Keyword.get(opts, :slug, "backgammon"))

    {:ok, _} =
      Game.configure(game_id, %{
        format: format,
        clock: Keyword.get(opts, :clock, "none"),
        seed: Keyword.get(opts, :seed, 42),
        control: Keyword.get(opts, :control)
      })

    g1 = unique_guest_id()
    {:ok, p1, _state} = Game.join_game(game_id, "Alice", Keyword.get(opts, :pid1), g1)
    %{game_id: game_id, p1: p1, g1: g1}
  end

  @doc """
  A guest id, shaped exactly as the cookie plug mints one (22 URL-safe
  characters), so a test can put it in a real guest cookie and be seated.
  """
  def unique_guest_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  @doc """
  A backgammon game that started when Bob joined. `mover` is the player to
  move (the opening roll decides), `waiting` the other one; `mover_guest`
  and `waiting_guest` are the guests holding those seats.
  """
  def started(seed \\ 42, format \\ "single", opts \\ []) do
    fixture = lobby(format, Keyword.put(opts, :seed, seed))
    g2 = unique_guest_id()
    {:ok, p2, state} = Game.join_game(fixture.game_id, "Bob", Keyword.get(opts, :pid2), g2)
    true = state.instance != nil
    mover = mover(state.instance, [fixture.p1, p2])
    waiting = if mover == fixture.p1, do: p2, else: fixture.p1
    guest_of = %{fixture.p1 => fixture.g1, p2 => g2}

    fixture
    |> Map.put(:p2, p2)
    |> Map.put(:g2, g2)
    |> Map.put(:state, state)
    |> Map.put(:mover, mover)
    |> Map.put(:waiting, waiting)
    |> Map.put(:mover_guest, guest_of[mover])
    |> Map.put(:waiting_guest, guest_of[waiting])
  end

  @doc "The guest holding a seat in a room."
  def guest_for(game_id, player_id) do
    game_id |> Game.get_server_state() |> GameServerState.guest_for(player_id)
  end

  @doc "Whoever has something to do beyond resigning: the player to move."
  def mover(instance, players) do
    Enum.find(players, fn p ->
      Enum.any?(GameKit.player_update(instance, p)["legal"], &(&1["name"] != "resign"))
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
