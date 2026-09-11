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

  # A join from a named browser tab: `client` is what the real client mints
  # per tab, and the transport is the websocket under it -- a fresh one every
  # time the connection comes back. Pass `transport: :elsewhere` for a socket
  # of its own; the default is the test process, whose pushes the test can
  # see.
  defp join_as(game_id, token, client, opts \\ []) do
    socket = socket(OskolWeb.UserSocket, "user", %{client: client})

    socket =
      case Keyword.get(opts, :transport) do
        :elsewhere -> %{socket | transport_pid: spawn(fn -> Process.sleep(:infinity) end)}
        _ -> socket
      end

    {:ok, reply, joined} =
      subscribe_and_join(socket, OskolWeb.GameChannel, "game:#{game_id}", %{"token" => token})

    {reply, joined}
  end

  # A join from another browser. Every socket in a test shares the test
  # process as its transport, which is what the room falls back to reading as
  # "the same client", so a second tab has to be spelled out.
  defp join_as_other_client(game_id, token) do
    other_browser = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, reply, socket} =
      %{socket(OskolWeb.UserSocket, "user", %{}) | transport_pid: other_browser}
      |> subscribe_and_join(OskolWeb.GameChannel, "game:#{game_id}", %{"token" => token})

    {reply, socket}
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

  test "the same client rejoining its seat resumes quietly" do
    # A reload, a route change, a socket that came back: the same browser
    # picking its game up again. It must not be told it lost the seat.
    %{game_id: game_id, p1: p1, t1: t1} = started()
    {_, first} = join_room(game_id, t1)
    Process.unlink(first.channel_pid)
    flush_updates()

    {reply, second} = join_room(game_id, t1)
    assert reply.payload.player_id == p1
    refute_receive %Phoenix.Socket.Message{event: "error"}, 300
    # The seat is live, and it is the new connection that holds it.
    state = Game.get_server_state(game_id)
    assert state.connections[p1].connected
    assert state.connections[p1].pid == second.channel_pid
  end

  test "a tab whose socket dropped and came back is not a new player" do
    # The phone slept and woke up: a brand new websocket, the same tab. The
    # seat is identified by the tab, so the room resumes it in silence even
    # though the old socket has not been noticed dying yet.
    %{game_id: game_id, p1: p1, t1: t1} = started()
    {_, first} = join_as(game_id, t1, "tab-1", transport: :elsewhere)
    Process.unlink(first.channel_pid)
    gone = Process.monitor(first.channel_pid)
    flush_updates()

    # The same tab on a brand new websocket, while the old one is still up.
    {reply, second} = join_as(game_id, t1, "tab-1")
    assert reply.payload.player_id == p1
    refute_receive {:DOWN, ^gone, :process, _, _}, 300
    refute_receive %Phoenix.Socket.Message{event: "error"}, 100
    state = Game.get_server_state(game_id)
    assert state.connections[p1].connected
    assert state.connections[p1].pid == second.channel_pid

    # A second tab on the same link is another client, whatever socket it
    # arrives on, and the one holding the seat is told.
    ref = Process.monitor(second.channel_pid)
    {_, _} = join_as(game_id, t1, "tab-2")
    assert_push "error", %{message: "This seat was opened somewhere else"}
    assert_receive {:DOWN, ^ref, :process, _, _}, 1000
  end

  test "another browser on the same token takes the seat over and the old one is told" do
    %{game_id: game_id, p1: p1, t1: t1} = started()
    {_, first} = join_room(game_id, t1)
    Process.unlink(first.channel_pid)
    ref = Process.monitor(first.channel_pid)
    flush_updates()

    {reply, _second} = join_as_other_client(game_id, t1)
    assert reply.payload.player_id == p1
    assert_push "error", %{message: "This seat was opened somewhere else"}
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
