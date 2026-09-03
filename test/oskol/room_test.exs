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
    %{game_id: game_id, p1: p1, p2: p2, state: state}
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
      %{game_id: game_id, p1: p1} = lobby("single", pid1: pid)
      assert Game.get_server_state(game_id).connections[p1].connected
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      assert_receive {:game_state_updated, %{instance: nil}, []}

      assert {:error, :player_not_found} = Game.rejoin_game(game_id, "Zed", self())
      assert {:ok, ^p1, state} = Game.rejoin_game(game_id, "Alice", self())
      assert state.connections[p1].connected
      assert {:error, :player_already_connected} = Game.rejoin_game(game_id, "Alice", self())
    end

    test "reconnecting mid-game keeps the seat and the running instance" do
      pid = sleeper()

      %{game_id: game_id, p1: p1, p2: p2, state: started} =
        room("backgammon", "single", pid1: pid, pid2: self())

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      # The game goes on: the instance is untouched and the seat is still theirs
      assert Game.get_server_state(game_id).instance == started.instance
      assert {:ok, ^p1, _} = Game.rejoin_game(game_id, "Alice", self())

      mover = mover(started.instance, [p1, p2])
      assert {:ok, _, events} = move(game_id, mover, legal_move(started.instance, mover))
      assert Enum.any?(events, &match?({:custom, "move_staged", _}, &1))
    end

    test "nobody can join a started game" do
      %{game_id: game_id} = room("backgammon", "single")
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)
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
      [new_p1 | _] = rematch.seat_order
      update = GameKit.player_update(rematch.instance, new_p1)
      assert update["clock"]["enabled"] == true
      assert update["clock"]["label"] == "3 min + 2 s"
      refute GameKit.finished?(rematch.instance)
    end
  end
end
