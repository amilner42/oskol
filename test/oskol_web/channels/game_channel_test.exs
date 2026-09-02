defmodule OskolWeb.GameChannelTest do
  use OskolWeb.ChannelCase, async: true

  import Oskol.GameFixtures

  alias Oskol.Game

  defp join_room(game_id, player_id) do
    {:ok, reply, socket} =
      OskolWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(OskolWeb.GameChannel, "game:#{game_id}", %{"player_id" => player_id})

    {reply, socket}
  end

  test "joining a lobby returns the lobby payload" do
    %{game_id: game_id, p1: p1} = lobby()
    {reply, _socket} = join_room(game_id, p1)
    assert reply.payload.type == "lobby"
    assert reply.payload.game == "tilt"
    assert Enum.map(reply.payload.connections, & &1.name) == ["Alice", "Bob"]
  end

  test "joining a running game returns this player's scene and legal actions" do
    %{game_id: game_id, p1: p1} = started()
    {reply, _socket} = join_room(game_id, p1)
    assert reply.payload.type == "game"
    assert reply.payload.player_id == p1
    assert reply.payload.update["scene"]["viewer"] == p1
    assert Enum.map(reply.payload.update["legal"], & &1["name"]) == ["play_hand", "discard"]
    assert reply.payload.update["events"] == []
  end

  test "an action pushes an update with events to everyone and errors only to the actor" do
    %{game_id: game_id, state: state, p1: p1, p2: p2} = started()
    {_, socket1} = join_room(game_id, p1)
    {_, _socket2} = join_room(game_id, p2)
    cards = hand_cards(state.instance, p1, 1)

    ref =
      push(socket1, "action", %{
        "action" => %{"name" => "play_hand", "params" => %{"cards" => cards}}
      })

    assert_reply ref, :ok

    assert_push "update", %{payload: payload}
    assert payload.type == "game"

    assert Enum.any?(
             payload.update["events"],
             &(&1["type"] == "custom" and &1["kind"] == "hand_locked_in")
           )

    ref =
      push(socket1, "action", %{
        "action" => %{"name" => "play_hand", "params" => %{"cards" => cards}}
      })

    assert_reply ref, :ok
    assert_push "error", %{message: "Already locked in"}
  end

  test "malformed actions are refused at the channel" do
    %{game_id: game_id, p1: p1} = started()
    {_, socket} = join_room(game_id, p1)
    ref = push(socket, "action", %{"action" => "play_hand"})
    assert_reply ref, :error, %{reason: _}
  end

  test "rematch before the game ends is an error reply" do
    %{game_id: game_id, p1: p1} = started()
    {_, socket} = join_room(game_id, p1)
    ref = push(socket, "rematch", %{})
    assert_reply ref, :error, %{reason: "game_not_finished"}
  end

  test "joining an unknown game fails" do
    assert {:error, %{reason: "Game not found"}} =
             OskolWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(OskolWeb.GameChannel, "game:missing", %{"player_id" => "x"})
  end

  test "spectators get a scene without legal actions" do
    %{game_id: game_id} = started()
    {reply, _socket} = join_room(game_id, "spectator-1")
    assert reply.payload.update["legal"] == []
    assert reply.payload.update["scene"]["viewer"] == nil
    assert Game.get_server_state(game_id).connections |> map_size() == 2
  end
end
