defmodule OskolWeb.GameChannelConnectionTest do
  @moduledoc "Channel joins register the live connection; leaving frees the seat for a reconnect."
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

  defp connected?(game_id, player_id) do
    Game.get_server_state(game_id).connections[player_id].connected
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  test "a channel join connects the seat, closing it disconnects, rejoining reconnects" do
    %{game_id: game_id, p1: p1} = started()
    refute connected?(game_id, p1)

    {_, socket} = join_room(game_id, p1)
    assert connected?(game_id, p1)

    Process.unlink(socket.channel_pid)
    close(socket)
    assert eventually(fn -> not connected?(game_id, p1) end)

    {reply, _socket} = join_room(game_id, p1)
    assert connected?(game_id, p1)
    assert reply.payload.type == "game"
    assert reply.payload.update["scene"]["viewer"] == p1
    assert Enum.map(reply.payload.players, & &1.connected) == [true, false]
  end

  test "spectators receive every update without legal actions" do
    %{game_id: game_id, state: state, mover: mover} = started()
    {_, _watcher} = join_room(game_id, "watcher")
    {:ok, _, _} = move(game_id, mover, legal_move(state.instance, mover))

    assert_push "update", %{payload: payload}
    assert payload.player_id == "watcher"
    assert payload.update["legal"] == []
    assert payload.update["scene"]["viewer"] == nil
    assert Enum.any?(payload.update["events"], &(&1["kind"] == "move_staged"))
  end

  test "an update for one player never carries another player's legal actions" do
    %{game_id: game_id, state: state, mover: mover, waiting: waiting} = started()
    {_, _socket2} = join_room(game_id, waiting)
    {:ok, _, _} = move(game_id, mover, legal_move(state.instance, mover))

    assert_push "update", %{payload: payload}
    assert payload.player_id == waiting
    assert payload.update["scene"]["viewer"] == waiting
    # The mover's staged move is private: the waiting player still only sees resign
    assert Enum.map(payload.update["legal"], & &1["name"]) == ["resign"]
  end
end
