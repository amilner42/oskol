defmodule Oskol.Game.RoomTest do
  @moduledoc """
  The generic room driven by random bots and by disconnecting players: every
  registered game through the Elixir/Gleam bridge, many rooms at once,
  reconnects mid-game, and rematches that keep the format and the clock.
  """
  use ExUnit.Case, async: true

  import Oskol.GameFixtures

  alias Oskol.{Bots, Game, GameKit}
  alias Oskol.Game.GameServer

  defp room(slug, format, opts \\ []) do
    game_id = unique_game_id(slug)
    {:ok, _} = Game.start_game(game_id, slug)
    {:ok, p1, _} = Game.join_game(game_id, "Alice", Keyword.get(opts, :pid1))
    {:ok, p2, _} = Game.join_game(game_id, "Bob", Keyword.get(opts, :pid2))

    for p <- [p1, p2] do
      {:ok, _} = Game.select_format(game_id, p, format)
      {:ok, _} = Game.select_clock(game_id, p, Keyword.get(opts, :clock, "none"))
    end

    %{game_id: game_id, p1: p1, p2: p2}
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
        %{game_id: game_id, p1: p1, p2: p2} = room(@slug, @format)
        {:ok, _} = GameServer.start_game(game_id, 11)
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

        # Short formats always end within the cap
        if @format in ["short", "single"], do: assert(match?({:finished, _}, result))

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
            slug = if rem(n, 2) == 0, do: "tilt", else: "backgammon"
            format = if slug == "tilt", do: "short", else: "single"
            %{game_id: game_id} = room(slug, format)
            {:ok, _} = GameServer.start_game(game_id, n)
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
    test "a player whose process dies is marked disconnected and can rejoin" do
      pid = sleeper()
      %{game_id: game_id, p1: p1} = room("tilt", "short", pid1: pid, pid2: self())
      assert Game.get_server_state(game_id).lobby_status == :ready_to_start
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      assert_receive {:game_state_updated, %{lobby_status: :waiting_for_players}, []}

      assert {:error, :player_not_found} = Game.rejoin_game(game_id, "Zed", self())
      assert {:ok, ^p1, state} = Game.rejoin_game(game_id, "Alice", self())
      assert state.connections[p1].connected
      assert state.lobby_status == :ready_to_start
      assert {:error, :player_already_connected} = Game.rejoin_game(game_id, "Alice", self())
    end

    test "reconnecting mid-game keeps the seat and the running instance" do
      pid = sleeper()
      %{game_id: game_id, p1: p1} = room("tilt", "short", pid1: pid, pid2: self())
      {:ok, started} = GameServer.start_game(game_id, 5)

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      # The game goes on: the instance is untouched and the seat is still theirs
      assert Game.get_server_state(game_id).instance == started.instance
      assert {:ok, ^p1, _} = Game.rejoin_game(game_id, "Alice", self())

      cards = hand_cards(started.instance, p1, 1)
      assert {:ok, _, events} = play(game_id, p1, cards)
      assert Enum.any?(events, &match?({:custom, "hand_locked_in", _}, &1))
    end

    test "nobody can join a started game, and a third seat is refused" do
      %{game_id: game_id} = room("backgammon", "single")
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)
      {:ok, _} = GameServer.start_game(game_id, 1)
      assert {:error, :game_full} = Game.join_game(game_id, "Carol", nil)
    end
  end

  describe "rematch" do
    test "keeps the format and the time control" do
      %{game_id: game_id, p1: p1, p2: p2} = room("tilt", "short", clock: "blitz")
      {:ok, state} = GameServer.start_game(game_id, 8)
      assert GameKit.player_update(state.instance, p1)["clock"]["enabled"] == true

      assert {:finished, _} = Bots.play(game_id, 8, 3000)
      assert {:ok, nil} = Game.request_rematch(game_id, p1)
      assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)

      rematch = Game.get_server_state(rematch_id)
      assert Map.values(rematch.format_selections) |> Enum.uniq() == ["short"]
      assert Map.values(rematch.clock_selections) |> Enum.uniq() == ["blitz"]
      [new_p1 | _] = rematch.seat_order
      update = GameKit.player_update(rematch.instance, new_p1)
      assert update["clock"]["enabled"] == true
      assert update["clock"]["label"] =~ ~r/blitz/i or update["clock"]["label"] != ""
      refute GameKit.finished?(rematch.instance)
    end
  end
end
