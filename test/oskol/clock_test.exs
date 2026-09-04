defmodule Oskol.Game.ClockTest do
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.GameKit

  test "clock presets are offered, a game says which, and none is the default" do
    assert [%{"id" => "none"} | _] = GameKit.clock_presets()
    {:ok, info} = GameKit.game_info("backgammon")
    assert "blitz" in info["clocks"]
    assert info["default_clock"] == "none"
    %{game_id: game_id} = lobby()
    assert Game.get_server_state(game_id).setup.clock == "none"
  end

  test "the creator picks the time control and it applies when the game starts" do
    %{game_id: game_id, p1: p1} = lobby("single", clock: "blitz")
    assert {:error, :unknown_clock} = Game.configure(game_id, %{clock: "hourglass"})
    {:ok, _p2, started} = Game.join_game(game_id, "Bob", nil)
    assert GameKit.player_update(started.instance, p1)["clock"]["label"] == "3 min + 2 s"
  end

  test "updates carry the clock and a game with no clock has it disabled" do
    %{state: state, p1: p1} = started()
    update = GameKit.player_update(state.instance, p1)
    assert update["clock"]["enabled"] == false
    assert Enum.map(update["clock"]["players"], & &1["running"]) == [false, false]
  end

  test "a player who runs out of time forfeits and everyone is told" do
    %{game_id: game_id, p1: p1} = lobby("single", seed: 11, control: {:fischer, 150, 0})
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
    # Only the player to move is charged; 150 ms.
    {:ok, p2, state} = Game.join_game(game_id, "Bob", nil)
    mover = mover(state.instance, [p1, p2])
    waiting = if mover == p1, do: p2, else: p1
    update = GameKit.player_update(state.instance, p1)
    assert update["clock"]["enabled"]
    assert update["clock"]["label"] == "0 min + 0 s"
    running = update["clock"]["players"] |> Enum.filter(& &1["running"]) |> Enum.map(& &1["id"])
    assert running == [mover]

    # First broadcast is the start itself; the next one is the forfeit.
    assert_receive {:game_state_updated, _started, []}
    assert_receive {:game_state_updated, %{instance: instance}, events}, 1000
    assert GameKit.finished?(instance)
    assert {:finished, [^waiting]} = GameKit.outcome(instance)
    assert Enum.any?(events, &(&1 |> elem(0) == :message))

    # The game refuses further play but still answers with an update
    assert {:error, "The game is over"} = Game.player_action(game_id, mover, simple("roll"))
    assert GameKit.player_update(instance, waiting)["clock"]["timed_out"] == mover
  end

  test "a turn-based game only charges the player to move" do
    %{state: state, p1: p1} = started(3, "single", control: {:fischer, 60_000, 1000})
    update = GameKit.player_update(state.instance, p1)
    running = update["clock"]["players"] |> Enum.filter(& &1["running"]) |> Enum.map(& &1["id"])
    assert running == [update["scene"]["data"]["to_move"]]
  end
end
