defmodule Oskol.GameTest do
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.Game

  describe "game codes" do
    test "a game code is exactly 6 digits" do
      for _ <- 1..50 do
        assert Game.generate_game_id() =~ ~r/^\d{6}$/
      end
    end

    test "creating a game mints a 6-digit code and starts a live room" do
      assert {:ok, game_id} = Game.create_game("backgammon")
      assert game_id =~ ~r/^\d{6}$/
      assert {:ok, _pid} = Game.lookup_game(game_id)
      assert Game.get_server_state(game_id).slug == "backgammon"
    end

    test "a collision with a live room mints again until the code is free" do
      {:ok, taken} = Game.create_game("backgammon")

      # A generator that insists on the taken code twice before yielding
      # fresh ones: create_game must skip the collisions and land on a
      # different code.
      {:ok, agent} =
        Agent.start_link(fn ->
          [taken, taken] ++ Enum.map(1..5, fn _ -> Game.generate_game_id() end)
        end)

      generate = fn -> Agent.get_and_update(agent, fn [h | t] -> {h, t} end) end

      assert {:ok, game_id} = Game.create_game("backgammon", generate)
      refute game_id == taken
      # Both collisions and the winner were drawn from the generator.
      assert Agent.get(agent, &length/1) <= 4

      # Both rooms are alive and distinct.
      assert {:ok, pid_a} = Game.lookup_game(taken)
      assert {:ok, pid_b} = Game.lookup_game(game_id)
      refute pid_a == pid_b
    end

    test "running out of attempts gives up rather than looping" do
      {:ok, taken} = Game.create_game("backgammon")
      assert {:error, :no_free_id} = Game.create_game("backgammon", fn -> taken end, 5)
    end

    test "an unknown slug never mints a room" do
      assert {:error, :unknown_game} = Game.create_game("checkers")
    end
  end

  describe "lookup_slug/1" do
    test "resolves a live room's code to its slug" do
      game_id = unique_game_id()
      {:ok, _} = Game.start_game(game_id, "poker")
      assert {:ok, "poker"} = Game.lookup_slug(game_id)
    end

    test "a code with no live room is simply not found" do
      assert :not_found = Game.lookup_slug("000000")
      assert :not_found = Game.lookup_slug("no-such-room")
    end
  end
end
