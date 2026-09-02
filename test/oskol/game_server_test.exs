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
      {:ok, _} = Game.start_game(game_id, "tilt")
      {:ok, p1, state} = Game.join_game(game_id, "Alice", self())
      assert state.lobby_status == :waiting_for_players
      {:ok, p2, _} = Game.join_game(game_id, "Bob", self())
      {:ok, _} = Game.select_format(game_id, p1, "standard")
      {:ok, state} = Game.select_format(game_id, p2, "standard")
      assert state.lobby_status == :ready_to_start
      assert state.seat_order == [p1, p2]
    end

    test "different formats do not make the lobby ready" do
      %{game_id: game_id, p2: p2} = lobby("short")
      {:ok, state} = Game.select_format(game_id, p2, "extended")
      assert state.lobby_status == :waiting_for_players
      assert {:error, :no_format_agreement} = Game.start_game_session(game_id)
    end

    test "rejects unknown formats, duplicate names, and a third player" do
      %{game_id: game_id, p1: p1} = lobby()
      assert {:error, :unknown_format} = Game.select_format(game_id, p1, "marathon")
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)

      other = unique_game_id()
      {:ok, _} = Game.start_game(other, "tilt")
      {:ok, _, _} = Game.join_game(other, "Alice", nil)
      assert {:error, :name_taken} = Game.join_game(other, "Alice", nil)
    end
  end

  describe "playing" do
    test "starting creates an instance and each player gets their own update" do
      %{state: state, p1: p1, p2: p2} = started()
      assert state.instance != nil
      assert state.seed == 42
      u1 = GameKit.player_update(state.instance, p1)
      u2 = GameKit.player_update(state.instance, p2)
      assert u1["scene"]["viewer"] == p1
      assert u2["scene"]["viewer"] == p2
      assert Enum.map(u1["legal"], & &1["name"]) == ["play_hand", "discard"]
      assert u1["outcome"] == %{"status" => "ongoing"}
    end

    test "the same seed deals the same cards" do
      a = started(7)
      b = started(7)
      # Card ids embed the player id, so compare faces
      assert hand_faces(a.state.instance, a.p1) == hand_faces(b.state.instance, b.p1)
      assert length(hand_faces(a.state.instance, a.p1)) == 8
    end

    test "actions apply, broadcast, and reject illegal moves without changing state" do
      %{game_id: game_id, state: state, p1: p1, p2: p2} = started()
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      cards = hand_cards(state.instance, p1, 2)

      assert {:ok, after_play, events} = play(game_id, p1, cards)
      assert length(events) == 3
      expected_instance = after_play.instance
      assert_receive {:game_state_updated, %{instance: ^expected_instance}, _events}

      assert {:error, "Already locked in"} = play(game_id, p1, cards)
      assert {:error, "Card not in hand"} = play(game_id, p2, ["nope"])

      assert {:error, "Unknown action: fly"} =
               Game.player_action(game_id, p2, %{"name" => "fly", "params" => %{}})

      assert GameServer.get_state(game_id).instance == after_play.instance
    end

    test "async actions report failures over pubsub to the acting player" do
      %{game_id: game_id, p1: p1} = started()
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      Game.player_action_async(game_id, p1, %{"name" => "play_hand", "params" => %{"cards" => []}})

      assert_receive {:action_failed, ^p1, "Play between 1 and 5 cards"}
    end

    test "actions before start and from strangers are rejected" do
      %{game_id: game_id, p1: p1} = lobby()
      assert {:error, :game_not_started} = play(game_id, p1, ["AS"])
      %{game_id: started_id} = started()
      assert {:error, :player_not_found} = play(started_id, "ghost", ["AS"])
    end
  end

  describe "rematch" do
    test "requires a finished game" do
      %{game_id: game_id, p1: p1} = started()
      assert {:error, :game_not_finished} = Game.request_rematch(game_id, p1)
    end

    test "creates a new room with the same players and format once everyone is ready" do
      %{game_id: game_id, p1: p1, p2: p2} = fixture = started(3)
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      finish_game(fixture)
      assert GameKit.finished?(GameServer.get_state(game_id).instance)

      assert {:ok, nil} = Game.request_rematch(game_id, p1)
      assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)
      assert rematch_id == game_id <> "-r1"
      assert_receive {:rematch_ready, ^rematch_id}

      rematch = GameServer.get_state(rematch_id)
      assert rematch.instance != nil
      assert rematch.slug == "tilt"

      assert Enum.map(rematch.connections, fn {_id, c} -> c.name end) |> Enum.sort() == [
               "Alice",
               "Bob"
             ]

      assert Map.values(rematch.format_selections) |> Enum.uniq() == ["short"]
      # Asking again returns the same rematch id
      assert {:ok, ^rematch_id} = Game.request_rematch(game_id, p1)
    end
  end

  # Drive a game to the end by always playing one card and taking the first legal shop action.
  defp finish_game(%{game_id: game_id, p1: p1, p2: p2}) do
    Enum.reduce_while(1..2000, :ok, fn _, acc ->
      state = GameServer.get_state(game_id)

      if GameKit.finished?(state.instance) do
        {:halt, acc}
      else
        Enum.each([p1, p2], fn pid ->
          update = GameKit.player_update(state.instance, pid)

          case update["legal"] do
            [] ->
              :ok

            [schema | _] ->
              params =
                Map.new(schema["params"], fn param ->
                  count = max(param["min"], 1)
                  {param["name"], Enum.take(param["candidates"], count)}
                end)

              Game.player_action(game_id, pid, %{"name" => schema["name"], "params" => params})
          end
        end)

        {:cont, acc}
      end
    end)
  end

  defp hand_faces(instance, player) do
    GameKit.player_update(instance, player)["scene"]["zones"]
    |> Enum.find(&(&1["id"] == "hand:#{player}"))
    |> Map.fetch!("tokens")
    |> Enum.map(&{&1["props"]["rank"], &1["props"]["suit"]})
  end
end
