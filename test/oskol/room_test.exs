defmodule Oskol.Game.RoomTest do
  @moduledoc """
  The generic room driven by random bots and by disconnecting players: every
  registered game through the Elixir/Gleam bridge, many rooms at once,
  reconnects mid-game, and rematches that keep the setup.
  """
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.{Bots, Game, GameKit}

  # A room the creator set up, with both players seated: it has started.
  defp room(slug, format, opts \\ []) do
    game_id = unique_game_id(slug)
    {:ok, _} = Game.start_game(game_id, slug)

    {:ok, _} =
      Game.configure(game_id, %{
        format: format,
        clock: Keyword.get(opts, :clock, "none"),
        seed: Keyword.get(opts, :seed, 11)
      })

    {:ok, p1, _} = Game.join_game(game_id, "Alice", Keyword.get(opts, :pid1))
    {:ok, p2, state} = Game.join_game(game_id, "Bob", Keyword.get(opts, :pid2))

    %{
      game_id: game_id,
      p1: p1,
      p2: p2,
      t1: Oskol.Game.GameServerState.token_for(state, p1),
      t2: Oskol.Game.GameServerState.token_for(state, p2),
      state: state
    }
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

  defp sleeper do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "random bots through the room" do
    for game <- GameKit.games(), format <- game["formats"] do
      @slug game["slug"]
      @format format["id"]

      test "#{@slug} #{@format}: no legal action is ever rejected and the game ends or is cut off" do
        %{game_id: game_id, p1: p1, p2: p2, state: started} = room(@slug, @format)
        assert started.instance != nil
        result = Bots.play(game_id, 11, 1500)
        state = Game.get_server_state(game_id)

        case result do
          {:finished, steps} ->
            assert steps > 0
            assert GameKit.finished?(state.instance)

            assert %{"status" => "finished"} =
                     GameKit.player_update(state.instance, p1)["outcome"]

          {:cut_off, 1500} ->
            refute GameKit.finished?(state.instance)

          other ->
            flunk("bots ended with #{inspect(other)}")
        end

        # A single game always ends within the cap
        if @format == "single", do: assert(match?({:finished, _}, result))

        for p <- [p1, p2] do
          update = GameKit.player_update(state.instance, p)
          assert update["scene"]["viewer"] == p
          assert update["clock"]["enabled"] == false
        end

        assert GameKit.spectator_update(state.instance)["legal"] == []
      end
    end

    test "many rooms play at once without interfering" do
      results =
        1..12
        |> Task.async_stream(
          fn n ->
            format = if rem(n, 2) == 0, do: "single", else: "match3"
            %{game_id: game_id} = room("backgammon", format, seed: n)
            {game_id, Bots.play(game_id, n, 120)}
          end,
          max_concurrency: 12,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert length(results) == 12

      for {game_id, result} <- results do
        assert match?({:finished, _}, result) or match?({:cut_off, 120}, result)
        state = Game.get_server_state(game_id)
        assert state.instance != nil
        assert map_size(state.connections) == 2
      end
    end
  end

  describe "connections" do
    test "a creator whose process dies is marked disconnected and can come back" do
      pid = sleeper()
      %{game_id: game_id, p1: p1, t1: t1} = lobby("single", pid1: pid)
      assert Game.get_server_state(game_id).connections[p1].connected
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      assert_receive {:game_state_updated, %{instance: nil}, []}

      # A name is not a credential, and neither is the public player id.
      assert {:error, :invalid_token} = Game.attach(game_id, "Alice", self())
      assert {:error, :invalid_token} = Game.attach(game_id, p1, self())
      assert {:error, :invalid_token} = Game.attach(game_id, nil, self())

      assert {:ok, ^p1, state} = Game.attach(game_id, t1, self())
      assert state.connections[p1].connected
      # A newer connection replaces the live one: a phone coming back before
      # its old socket closed must not end up untracked.
      newer = sleeper()
      assert {:ok, ^p1, state} = Game.attach(game_id, t1, newer)
      assert state.connections[p1].pid == newer
      assert state.connections[p1].connected
    end

    test "a seat with a live player can only be reached with its own token" do
      pid = sleeper()
      %{game_id: game_id, p1: p1, t1: t1} = lobby("single", pid1: pid)
      assert Game.get_server_state(game_id).connections[p1].connected

      # Locked while connected: the invite link cannot take this seat.
      assert {:error, :seat_connected} = Game.claim_seat(game_id, p1, self())
      assert {:error, :invalid_token} = Game.attach(game_id, "guess", self())
      # The token still works: the same person on a second device.
      assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())
    end

    test "reclaiming an empty seat rotates its token" do
      %{game_id: game_id, p1: p1, t1: old} = lobby("single")
      refute Game.get_server_state(game_id).connections[p1].connected

      assert {:ok, ^p1, new_token, state} = Game.claim_seat(game_id, p1, self())
      refute new_token == old
      assert state.connections[p1].connected
      assert state.connections[p1].name == "Alice"
      # The leaked link is dead; the fresh one is the seat.
      assert {:error, :invalid_token} = Game.attach(game_id, old, self())
      assert {:ok, ^p1, _} = Game.attach(game_id, new_token, self())
      assert {:error, :player_not_found} = Game.claim_seat(game_id, "nobody", self())
    end

    test "reconnecting mid-game keeps the seat and the running instance" do
      pid = sleeper()

      %{game_id: game_id, p1: p1, t1: t1, p2: p2, state: started} =
        room("backgammon", "single", pid1: pid, pid2: self())

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      # The game goes on: the instance is untouched and the seat is still theirs
      assert Game.get_server_state(game_id).instance == started.instance
      assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())

      mover = mover(started.instance, [p1, p2])
      assert {:ok, _, events} = move(game_id, mover, legal_move(started.instance, mover))
      assert Enum.any?(events, &match?({:custom, "move_staged", _}, &1))
    end

    test "nobody can join a started game" do
      %{game_id: game_id} = room("backgammon", "single")
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)
    end
  end

  describe "lifecycle" do
    test "an idle room stops for good and is not restarted" do
      %{game_id: game_id} = room("backgammon", "single", seed: 3)
      {:ok, pid} = Game.lookup_game(game_id)
      ref = Process.monitor(pid)

      send(pid, :timeout)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      children = DynamicSupervisor.which_children(Oskol.Game.GameSupervisor)
      refute Enum.any?(children, fn {_, child, _, _} -> child == pid end)
      # The registry drops the name a moment after the process is gone
      assert eventually(fn -> Game.lookup_game(game_id) == :not_found end, 300)
    end
  end

  describe "rematch" do
    test "keeps the format and the time control" do
      %{game_id: game_id, p1: p1, p2: p2, state: state} =
        room("backgammon", "single", clock: "blitz", seed: 8)

      assert GameKit.player_update(state.instance, p1)["clock"]["enabled"] == true

      assert {:finished, _} = Bots.play(game_id, 8, 6000)
      assert {:ok, nil} = Game.request_rematch(game_id, p1)
      assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)

      rematch = Game.get_server_state(rematch_id)
      assert rematch.setup.format == "single"
      assert rematch.setup.clock == "blitz"
      # Same players, same seats, same tokens: the link each player holds
      # carries them into the new room.
      original = Game.get_server_state(game_id)
      assert rematch.seat_order == original.seat_order

      for id <- original.seat_order do
        assert rematch.connections[id].name == original.connections[id].name
        assert rematch.connections[id].token == original.connections[id].token
      end

      [new_p1 | _] = rematch.seat_order
      update = GameKit.player_update(rematch.instance, new_p1)
      assert update["clock"]["enabled"] == true
      assert update["clock"]["label"] == "3 min + 2 s"
      refute GameKit.finished?(rematch.instance)
    end
  end
end
