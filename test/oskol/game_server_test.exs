defmodule Oskol.Game.GameServerTest do
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.GameServer
  alias Oskol.GameKit

  describe "lobby" do
    test "unknown game slug is rejected" do
      assert {:error, :unknown_game} = Game.start_game(unique_game_id(), "chess")
    end

    test "players join, agree on a format, and become ready" do
      game_id = unique_game_id()
      {:ok, _} = Game.start_game(game_id, "backgammon")
      {:ok, p1, state} = Game.join_game(game_id, "Alice", self())
      assert state.lobby_status == :waiting_for_players
      {:ok, p2, _} = Game.join_game(game_id, "Bob", self())
      {:ok, _} = Game.select_format(game_id, p1, "match3")
      {:ok, state} = Game.select_format(game_id, p2, "match3")
      assert state.lobby_status == :ready_to_start
      assert state.seat_order == [p1, p2]
    end

    test "different formats do not make the lobby ready" do
      %{game_id: game_id, p2: p2} = lobby("single")
      {:ok, state} = Game.select_format(game_id, p2, "match5")
      assert state.lobby_status == :waiting_for_players
      assert {:error, :no_format_agreement} = Game.start_game_session(game_id)
    end

    test "rejects unknown formats, duplicate names, and a third player" do
      %{game_id: game_id, p1: p1} = lobby()
      assert {:error, :unknown_format} = Game.select_format(game_id, p1, "marathon")
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)

      other = unique_game_id()
      {:ok, _} = Game.start_game(other, "backgammon")
      {:ok, _, _} = Game.join_game(other, "Alice", nil)
      assert {:error, :name_taken} = Game.join_game(other, "Alice", nil)
    end
  end

  describe "playing" do
    test "starting creates an instance and each player gets their own update" do
      %{state: state, p1: p1, p2: p2, mover: mover, waiting: waiting} = started()
      assert state.instance != nil
      assert state.seed == 42
      u1 = GameKit.player_update(state.instance, p1)
      u2 = GameKit.player_update(state.instance, p2)
      assert u1["scene"]["viewer"] == p1
      assert u2["scene"]["viewer"] == p2

      assert Enum.any?(
               GameKit.player_update(state.instance, mover)["legal"],
               &(&1["name"] == "move")
             )

      assert Enum.map(GameKit.player_update(state.instance, waiting)["legal"], & &1["name"]) ==
               ["resign"]

      assert u1["outcome"] == %{"status" => "ongoing"}
    end

    test "the same seed rolls the same opening dice" do
      a = started(7)
      b = started(7)
      roll = fn s -> GameKit.player_update(s.instance, "x")["scene"]["data"]["last_roll"] end
      assert roll.(a.state) == roll.(b.state)
      assert length(roll.(a.state)) == 2
    end

    test "actions apply, broadcast, and reject illegal moves without changing state" do
      %{game_id: game_id, state: state, mover: mover, waiting: waiting} = started()
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      action = legal_move(state.instance, mover)

      assert {:ok, after_move, events} = move(game_id, mover, action)
      assert Enum.any?(events, &match?({:custom, "move_staged", _}, &1))
      expected_instance = after_move.instance
      assert_receive {:game_state_updated, %{instance: ^expected_instance}, _events}

      assert {:error, "Not your turn"} = move(game_id, waiting, action)

      assert {:error, "Illegal move"} =
               move(game_id, mover, %{"name" => "move", "params" => %{"from" => "3", "to" => "2"}})

      assert {:error, "Unknown action: fly"} =
               Game.player_action(game_id, mover, %{"name" => "fly", "params" => %{}})

      assert GameServer.get_state(game_id).instance == after_move.instance
    end

    test "async actions report failures over pubsub to the acting player" do
      %{game_id: game_id, mover: mover} = started()
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      Game.player_action_async(game_id, mover, simple("play"))

      assert_receive {:action_failed, ^mover, "You still have moves to play"}
    end

    test "actions before start and from strangers are rejected" do
      %{game_id: game_id, p1: p1} = lobby()
      assert {:error, :game_not_started} = move(game_id, p1, simple("roll"))
      %{game_id: started_id} = started()
      assert {:error, :player_not_found} = move(started_id, "ghost", simple("roll"))
    end
  end

  describe "rematch" do
    test "requires a finished game" do
      %{game_id: game_id, p1: p1} = started()
      assert {:error, :game_not_finished} = Game.request_rematch(game_id, p1)
    end

    test "creates a new room with the same players and format once everyone is ready" do
      %{game_id: game_id, p1: p1, p2: p2} = started(3)
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      assert {:finished, _} = Oskol.Bots.play(game_id, 3, 6000)
      assert GameKit.finished?(GameServer.get_state(game_id).instance)

      assert {:ok, nil} = Game.request_rematch(game_id, p1)
      assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)
      assert rematch_id == game_id <> "-r1"
      assert_receive {:rematch_ready, ^rematch_id}

      rematch = GameServer.get_state(rematch_id)
      assert rematch.instance != nil
      assert rematch.slug == "backgammon"

      assert Enum.map(rematch.connections, fn {_id, c} -> c.name end) |> Enum.sort() == [
               "Alice",
               "Bob"
             ]

      assert Map.values(rematch.format_selections) |> Enum.uniq() == ["single"]
      # Asking again returns the same rematch id
      assert {:ok, ^rematch_id} = Game.request_rematch(game_id, p1)
    end
  end
end
