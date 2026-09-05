defmodule OskolWeb.GameChannelTest do
  use OskolWeb.ChannelCase, async: true

  import Oskol.GameFixtures

  alias Oskol.Game

  defp join_room(game_id, token) do
    {:ok, reply, socket} =
      OskolWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(OskolWeb.GameChannel, "game:#{game_id}", %{"token" => token})

    {reply, socket}
  end

  defp try_join(game_id, params) do
    OskolWeb.UserSocket
    |> socket("user", %{})
    |> subscribe_and_join(OskolWeb.GameChannel, "game:#{game_id}", params)
  end

  test "joining a room that has not started returns the lobby payload" do
    %{game_id: game_id, t1: t1} = lobby()
    {reply, _socket} = join_room(game_id, t1)
    assert reply.payload.type == "lobby"
    assert reply.payload.game == "backgammon"
    assert Enum.map(reply.payload.connections, & &1.name) == ["Alice"]
  end

  test "joining a running game returns this player's scene and legal actions" do
    %{game_id: game_id, mover: mover, mover_token: mt, waiting_token: wt} = started()
    {reply, _socket} = join_room(game_id, mt)
    assert reply.payload.type == "game"
    assert reply.payload.player_id == mover
    assert reply.payload.update["scene"]["viewer"] == mover
    assert Enum.any?(reply.payload.update["legal"], &(&1["name"] == "move"))
    assert reply.payload.update["events"] == []
    {reply, _socket} = join_room(game_id, wt)
    assert Enum.map(reply.payload.update["legal"], & &1["name"]) == ["resign"]
  end

  test "an action pushes an update with events to everyone and errors only to the actor" do
    %{game_id: game_id, state: state, mover: mover, mover_token: mt, waiting_token: wt} =
      started()

    {_, socket1} = join_room(game_id, mt)
    {_, socket2} = join_room(game_id, wt)
    # Each join announces a live seat to everyone; those updates carry no events
    flush_updates()
    action = legal_move(state.instance, mover)

    ref = push(socket1, "action", %{"action" => action})
    assert_reply ref, :ok

    assert_push "update", %{payload: payload}
    assert payload.type == "game"

    assert Enum.any?(
             payload.update["events"],
             &(&1["type"] == "custom" and &1["kind"] == "move_staged")
           )

    ref = push(socket2, "action", %{"action" => simple("undo")})
    assert_reply ref, :ok
    assert_push "error", %{message: "Nothing to undo"}
  end

  test "malformed actions are refused at the channel" do
    %{game_id: game_id, t1: t1} = started()
    {_, socket} = join_room(game_id, t1)
    ref = push(socket, "action", %{"action" => "move"})
    assert_reply ref, :error, %{reason: _}
  end

  test "rematch before the game ends is an error reply" do
    %{game_id: game_id, t1: t1} = started()
    {_, socket} = join_room(game_id, t1)
    ref = push(socket, "rematch", %{})
    assert_reply ref, :error, %{reason: "game_not_finished"}
  end

  test "joining an unknown game fails" do
    assert {:error, %{reason: "Game not found"}} =
             try_join("missing", %{"token" => "whatever"})
  end

  # The security bar: the seat token is the only credential, and nothing
  # else gets a view of the table.
  test "a join without a token is refused" do
    %{game_id: game_id} = started()
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{})
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"token" => nil})
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"token" => ""})
  end

  test "a join with a wrong token is refused" do
    %{game_id: game_id, p1: p1} = started()
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"token" => "not-a-token"})
    # A player id is public; it is not a credential.
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"player_id" => p1})
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"token" => p1})
  end

  test "a stale token stops working once the seat is reclaimed" do
    %{game_id: game_id, p1: p1, t1: stale} = started()
    {:ok, ^p1, fresh, _} = Game.claim_seat(game_id, p1, self())
    refute fresh == stale
    assert {:error, %{reason: "unauthorized"}} = try_join(game_id, %{"token" => stale})
    {reply, _socket} = join_room(game_id, fresh)
    assert reply.payload.player_id == p1
  end

  test "the same token twice takes the seat over and drops the older socket" do
    %{game_id: game_id, p1: p1, t1: t1} = started()
    {_, first} = join_room(game_id, t1)
    Process.unlink(first.channel_pid)
    ref = Process.monitor(first.channel_pid)

    {reply, _second} = join_room(game_id, t1)
    assert reply.payload.player_id == p1
    assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    # The seat is still live: the takeover must not have marked it away.
    assert Game.get_server_state(game_id).connections[p1].connected
  end

  defp flush_updates do
    receive do
      %Phoenix.Socket.Message{event: "update"} -> flush_updates()
    after
      100 -> :ok
    end
  end
end
