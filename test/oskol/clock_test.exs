defmodule Oskol.Game.ClockTest do
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.GameServer
  alias Oskol.GameKit

  test "clock presets are offered and default to none" do
    assert [%{"id" => "none"} | _] = GameKit.clock_presets()
    %{game_id: game_id, p1: p1} = lobby()
    state = GameServer.get_state(game_id)
    assert state.clock_selections[p1] == "none"
    assert Oskol.Game.GameServerState.check_clock_agreement(state) == {:ok, "none"}
  end

  test "players must agree on a time control" do
    %{game_id: game_id, p1: p1, p2: p2} = lobby()
    {:ok, state} = Game.select_clock(game_id, p1, "blitz")
    assert Oskol.Game.GameServerState.check_clock_agreement(state) == :no_agreement
    assert {:error, :no_format_agreement} = Game.start_game_session(game_id)
    assert {:error, :unknown_clock} = Game.select_clock(game_id, p2, "hourglass")
    {:ok, state} = Game.select_clock(game_id, p2, "blitz")
    assert Oskol.Game.GameServerState.check_clock_agreement(state) == {:ok, "blitz"}
    assert {:ok, started} = Game.start_game_session(game_id)
    assert GameKit.player_update(started.instance, p1)["clock"]["label"] == "3 min + 2 s"
  end

  test "updates carry the clock and a lobby with no clock has it disabled" do
    %{state: state, p1: p1} = started()
    update = GameKit.player_update(state.instance, p1)
    assert update["clock"]["enabled"] == false
    assert Enum.map(update["clock"]["players"], & &1["running"]) == [false, false]
  end

  test "a player who runs out of time forfeits and everyone is told" do
    %{game_id: game_id, p1: p1, p2: p2} = lobby()
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
    # Both Tilt players are on the clock at once; 150 ms each.
    {:ok, state} = GameServer.start_game(game_id, 11, {:fischer, 150, 0})
    update = GameKit.player_update(state.instance, p1)
    assert update["clock"]["enabled"]
    assert update["clock"]["label"] == "0 min + 0 s"
    assert Enum.all?(update["clock"]["players"], & &1["running"])

    # First broadcast is the start itself; the next one is the forfeit.
    assert_receive {:game_state_updated, _started, []}
    assert_receive {:game_state_updated, %{instance: instance}, events}, 1000
    assert GameKit.finished?(instance)
    assert {:finished, [^p2]} = GameKit.outcome(instance)
    assert Enum.any?(events, &(&1 |> elem(0) == :message))

    # The game refuses further play but still answers with an update
    assert {:error, "The game is over"} =
             Game.player_action(game_id, p1, %{"name" => "discard", "params" => %{"cards" => []}})

    assert GameKit.player_update(instance, p2)["clock"]["timed_out"] == p1
  end

  test "a turn-based game only charges the player to move" do
    game_id = unique_game_id("bg")
    {:ok, _} = Game.start_game(game_id, "backgammon")
    {:ok, p1, _} = Game.join_game(game_id, "Alice", nil)
    {:ok, p2, _} = Game.join_game(game_id, "Bob", nil)
    {:ok, _} = Game.select_format(game_id, p1, "single")
    {:ok, _} = Game.select_format(game_id, p2, "single")
    {:ok, state} = GameServer.start_game(game_id, 3, {:fischer, 60_000, 1000})
    update = GameKit.player_update(state.instance, p1)
    running = update["clock"]["players"] |> Enum.filter(& &1["running"]) |> Enum.map(& &1["id"])
    assert running == [update["scene"]["data"]["to_move"]]
  end
end
