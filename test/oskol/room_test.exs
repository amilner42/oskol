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

    g1 = Oskol.GameFixtures.unique_guest_id()
    g2 = Oskol.GameFixtures.unique_guest_id()
    {:ok, p1, _} = Game.join_game(game_id, "Alice", Keyword.get(opts, :pid1), g1)
    {:ok, p2, state} = Game.join_game(game_id, "Bob", Keyword.get(opts, :pid2), g2)

    %{game_id: game_id, p1: p1, p2: p2, g1: g1, g2: g2, state: state}
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
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single", pid1: pid)
      assert Game.get_server_state(game_id).connections[p1].connected
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      assert_receive {:game_state_updated, %{instance: nil}, []}

      # A name is not a credential, and neither is the public player id.
      assert {:error, :no_seat} = Game.attach(game_id, "Alice", self())
      assert {:error, :no_seat} = Game.attach(game_id, p1, self())
      assert {:error, :no_seat} = Game.attach(game_id, nil, self())

      assert {:ok, ^p1, state} = Game.attach(game_id, g1, self())
      assert state.connections[p1].connected
      # A newer connection replaces the live one: a phone coming back before
      # its old socket closed must not end up untracked.
      newer = sleeper()
      assert {:ok, ^p1, state} = Game.attach(game_id, g1, newer)
      assert state.connections[p1].pid == newer
      assert state.connections[p1].connected
    end

    test "a seat tells its own client coming back from another one taking it" do
      # The room is told which client each connection belongs to (a socket's
      # transport, one per browser). The same client reattaching is a
      # reconnect and nothing is said to the connection it replaces; a
      # different one takes the seat over, and the connection that had it
      # hears about it. The rule itself is `oskol/rooms/seat`.
      phone = sleeper()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")

      # Same browser, new channel: quiet.
      first = sleeper()
      assert {:ok, ^p1, _} = Game.attach(game_id, g1, first, phone)
      second = sleeper()
      assert {:ok, ^p1, state} = Game.attach(game_id, g1, second, phone)
      assert state.connections[p1].pid == second
      assert state.connections[p1].connected
      refute_receive :seat_taken_over, 100
      assert Process.alive?(first)

      # Another browser: the connection holding the seat is told.
      Game.attach(game_id, g1, self(), phone)
      laptop = sleeper()
      assert {:ok, ^p1, state} = Game.attach(game_id, g1, sleeper(), laptop)
      assert_receive :seat_taken_over, 100
      assert state.connections[p1].connected

      # And a seat nobody is holding just resumes, whoever turns up.
      state = Game.get_server_state(game_id)
      send(state.connections[p1].pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      assert {:ok, ^p1, state} = Game.attach(game_id, g1, self(), phone)
      assert state.connections[p1].connected
      refute_receive :seat_taken_over, 100
    end

    test "one browser holds one seat: a guest already seated cannot take a second" do
      # A guest id names one seat, so a second one would be a seat that
      # browser could never reach. Two players are two browsers.
      %{game_id: game_id, g1: g1} = lobby("single")
      assert {:error, :already_seated} = Game.join_game(game_id, "Alice2", nil, g1)
      # Someone else may still sit down, and a seat taken by no guest at all
      # (tooling, a seeded room) never blocks another.
      assert {:ok, _p2, _} = Game.join_game(game_id, "Bob", nil, "another-browser")
    end

    test "seats taken with no guest at all do not shadow each other" do
      %{game_id: game_id} = lobby("single", pid1: nil)
      assert {:ok, _p2, state} = Game.join_game(game_id, "Bob", nil, nil)
      # Nobody holds either seat, and no browser walks into one by accident.
      assert {:error, :no_seat} = Game.attach(game_id, nil, self())
      assert state.instance != nil
    end

    test "a seat with a live player can only be reached by the guest holding it" do
      pid = sleeper()
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single", pid1: pid)
      assert Game.get_server_state(game_id).connections[p1].connected

      # Locked while connected: the invite link cannot take this seat.
      assert {:error, :seat_connected} = Game.claim_seat(game_id, p1, self(), "a-stranger")
      assert {:error, :no_seat} = Game.attach(game_id, "a-stranger", self())
      # The guest still gets in: the same browser in a second tab.
      assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
    end

    test "a browser at one seat cannot claim the other one from the invite" do
      # The other door into a seat. Alice is playing; Bob's socket drops;
      # Alice opens the invite link and clicks Bob's seat. If that went
      # through, her guest would be written onto both seats -- and a guest
      # id names one seat, so she would hold whichever came first and Bob
      # would be locked out of the room entirely.
      %{game_id: game_id, p1: p1, g1: g1, p2: p2, g2: g2} =
        room("backgammon", "single", pid1: self(), pid2: sleeper())

      state = Game.get_server_state(game_id)
      send(state.connections[p2].pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p2].connected end)

      assert {:error, :already_seated} = Game.claim_seat(game_id, p2, self(), g1)
      # Both seats are still where they were, and both players still get in.
      assert Game.get_server_state(game_id).connections[p2].guest_id == g2
      assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
      assert {:ok, ^p2, _} = Game.attach(game_id, g2, self())
    end

    test "claiming back the seat you already hold is a reconnect, not a second seat" do
      # A player who closed the tab and came back through the invite link:
      # the seat is already theirs, so the claim is how they get a live
      # connection again.
      %{game_id: game_id, p1: p1, g1: g1} = lobby("single")

      assert {:ok, ^p1, state} = Game.claim_seat(game_id, p1, self(), g1)
      assert state.connections[p1].connected
      assert state.connections[p1].guest_id == g1
    end

    test "reclaiming an empty seat hands it to the guest that claimed it" do
      # A seat nobody is holding is free to whoever has the room code: that
      # is the friendly-game rule, and the claiming browser holds it after.
      %{game_id: game_id, p1: p1, g1: was_alice} = lobby("single")
      refute Game.get_server_state(game_id).connections[p1].connected

      assert {:ok, ^p1, state} = Game.claim_seat(game_id, p1, self(), "another-browser")
      assert state.connections[p1].connected
      assert state.connections[p1].name == "Alice"
      assert state.connections[p1].guest_id == "another-browser"
      # The browser that used to hold it is a stranger to the seat now.
      assert {:error, :no_seat} = Game.attach(game_id, was_alice, self())
      assert {:ok, ^p1, _} = Game.attach(game_id, "another-browser", self())
      assert {:error, :player_not_found} = Game.claim_seat(game_id, "nobody", self(), "whoever")
    end

    test "reconnecting mid-game keeps the seat and the running instance" do
      pid = sleeper()

      %{game_id: game_id, p1: p1, g1: g1, p2: p2, state: started} =
        room("backgammon", "single", pid1: pid, pid2: self())

      send(pid, :stop)
      assert eventually(fn -> not Game.get_server_state(game_id).connections[p1].connected end)
      # The game goes on: the instance is untouched and the seat is still theirs
      assert Game.get_server_state(game_id).instance == started.instance
      assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())

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
        room("backgammon", "single", clock: "bg3", seed: 8)

      assert GameKit.player_update(state.instance, p1)["clock"]["enabled"] == true

      assert {:finished, _} = Bots.play(game_id, 8, 6000)
      assert {:ok, nil} = Game.request_rematch(game_id, p1)
      assert {:ok, rematch_id} = Game.request_rematch(game_id, p2)

      rematch = Game.get_server_state(rematch_id)
      assert rematch.setup.format == "single"
      assert rematch.setup.clock == "bg3"
      # Same players, same seats, held by the same guests: both browsers
      # walk straight into the new room.
      original = Game.get_server_state(game_id)
      assert rematch.seat_order == original.seat_order

      for id <- original.seat_order do
        assert rematch.connections[id].name == original.connections[id].name
        assert rematch.connections[id].guest_id == original.connections[id].guest_id
        assert {:ok, ^id, _} = Game.attach(rematch_id, original.connections[id].guest_id, self())
      end

      [new_p1 | _] = rematch.seat_order
      update = GameKit.player_update(rematch.instance, new_p1)
      assert update["clock"]["enabled"] == true
      assert update["clock"]["label"] == "3 min, 12 s delay every turn"
      refute GameKit.finished?(rematch.instance)
    end
  end
end
