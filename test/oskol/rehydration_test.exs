defmodule Oskol.RehydrationTest do
  # Rooms and the persister write from their own processes: shared sandbox,
  # not async.
  use ExUnit.Case, async: false

  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.{GameServerState, GameSupervisor, Persister, Pruner}
  alias Oskol.GameKit
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      # Drain the write queue before the owner goes: a write mid-flight
      # against a dying connection would only add noise.
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # Stop a room the way a deploy or an idle shutdown does, and wait until
  # the registry has let go of the name.
  defp kill_room(game_id) do
    {:ok, pid} = GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    wait_unregistered(game_id)
  end

  defp wait_unregistered(game_id, tries \\ 100) do
    case GameSupervisor.find_game(game_id) do
      :error ->
        :ok

      {:ok, _} when tries > 0 ->
        Process.sleep(10)
        wait_unregistered(game_id, tries - 1)
    end
  end

  test "a game in play rehydrates mid-game: same view, same seats, play continues to a finish" do
    %{game_id: game_id, p1: p1, p2: p2, g1: g1, g2: g2} = started(42)
    assert {:cut_off, 20} = Oskol.Bots.play(game_id, 7, 20)

    before = Game.get_server_state(game_id)
    view_before = GameKit.player_update(before.instance, p1) |> Map.take(["scene", "legal"])

    Persister.flush()
    kill_room(game_id)

    # The lookup any entry point uses (invite link, the room URL, JOIN GAME
    # code, channel join) rehydrates the room.
    assert {:ok, _pid} = Game.lookup_game(game_id)

    state = Game.get_server_state(game_id)
    assert state.action_count == 20
    assert GameServerState.guest_for(state, p1) == g1
    assert GameServerState.guest_for(state, p2) == g2
    assert GameServerState.seats(state) == GameServerState.seats(before)

    # Replay is exact: the rehydrated instance projects the same scene and
    # offers the same legal actions.
    assert GameKit.player_update(state.instance, p1) |> Map.take(["scene", "legal"]) ==
             view_before

    # Both players' browsers still hold their seats.
    assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
    assert {:ok, ^p2, _} = Game.attach(game_id, g2, self())

    # And the game plays on to a finish, persisted as such.
    assert {:finished, more} = Oskol.Bots.play(game_id, 8, 5000)
    Persister.flush()
    row = Repo.get(Persistence.Game, game_id)
    assert row.status == "finished"
    assert length(Repo.all(Persistence.GameAction)) >= 20 + more
  end

  test "the row mirrors where the game stands after every step, and a wake writes it too" do
    %{game_id: game_id, mover: mover, waiting: waiting} = started(42)

    # At the start: it is the mover's turn, and the players are there with
    # their public counters.
    Persister.flush()
    row = Repo.get(Persistence.Game, game_id)
    assert same_snapshot?(row.state, GameKit.summary(Game.get_server_state(game_id).instance))
    assert is_integer(row.state["at"])
    assert row.state["to_act"] == [mover]
    assert row.state["outcome"] == %{"status" => "ongoing"}

    assert Enum.map(row.state["players"], & &1["id"]) |> Enum.sort() ==
             Enum.sort([mover, waiting])

    # After every step the row says what the instance does.
    Enum.each(1..6, fn _ ->
      assert {:cut_off, 1} = Oskol.Bots.play(game_id, 7, 1)
      Persister.flush()
      row = Repo.get(Persistence.Game, game_id)
      assert same_snapshot?(row.state, GameKit.summary(Game.get_server_state(game_id).instance))
    end)

    # A row from before the snapshot existed heals on the room's first wake.
    Persistence.mirror_state(game_id, nil)
    kill_room(game_id)
    assert {:ok, _pid} = Game.lookup_game(game_id)
    Persister.flush()
    row = Repo.get(Persistence.Game, game_id)
    assert same_snapshot?(row.state, GameKit.summary(Game.get_server_state(game_id).instance))
  end

  # The snapshot less its stamp: the clocks were read at different moments.
  defp same_snapshot?(a, b), do: Map.delete(a, "at") == Map.delete(b, "at")

  test "a waiting room rehydrates: the seat holds, and the game starts when the table fills" do
    %{game_id: game_id, p1: p1, g1: g1} = lobby("single", seed: 42)

    Persister.flush()
    kill_room(game_id)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    refute GameServerState.started?(state)
    assert GameServerState.guest_for(state, p1) == g1
    assert state.setup.format == "single"

    {:ok, _p2, joined} = Game.join_game(game_id, "Bob", nil)
    assert GameServerState.started?(joined)
    assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
  end

  # Plays a whole game before it can rehydrate one.
  @tag :slow
  test "a finished game rehydrates read-only: final position, no further actions" do
    %{game_id: game_id, p1: p1, g1: g1} = started(42)
    assert {:finished, _} = Oskol.Bots.play(game_id, 7, 5000)

    Persister.flush()
    kill_room(game_id)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    assert GameKit.finished?(state.instance)

    # The seat still shows the table (and would offer a rematch)...
    assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
    # ...but the engine refuses further play.
    assert {:error, _} = Game.player_action(game_id, p1, simple("roll"))
  end

  test "a room written before seat tokens were dropped still rebuilds, held by its guests" do
    # Live production rooms have rows whose seats carry a token. The key is
    # dead, and it must cost nothing: the room comes back, the guests that
    # were recorded on the seats still hold them, and the token opens
    # nothing (there is nowhere left to offer it).
    %{game_id: game_id, p1: p1, g1: g1, p2: p2, g2: g2} = started(42)
    assert {:cut_off, 6} = Oskol.Bots.play(game_id, 7, 6)
    Persister.flush()
    kill_room(game_id)

    row = Repo.get(Persistence.Game, game_id)

    Repo.update!(
      Ecto.Changeset.change(row,
        players: Enum.map(row.players, &Map.put(&1, "token", "tok-" <> &1["id"]))
      )
    )

    assert {:ok, _pid} = Game.lookup_game(game_id)
    assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
    assert {:ok, ^p2, _} = Game.attach(game_id, g2, self())
    assert {:error, :no_seat} = Game.attach(game_id, "tok-" <> p1, self())
  end

  test "a code with no live room and no row stays not found" do
    assert Game.lookup_game(unique_game_id("ghost")) == :not_found
  end

  test "deploy simulation: the whole room supervisor restarts and a half-played game carries on" do
    %{game_id: game_id, p1: p1, g1: g1} = started(42)
    assert {:cut_off, 15} = Oskol.Bots.play(game_id, 9, 15)
    Persister.flush()

    # A deploy: every room process dies with its supervisor.
    :ok = Supervisor.terminate_child(Oskol.Supervisor, GameSupervisor)
    {:ok, _} = Supervisor.restart_child(Oskol.Supervisor, GameSupervisor)
    # Registry sweeps dead rooms asynchronously; wait for the entry to clear.
    wait_until(fn -> GameSupervisor.find_game(game_id) == :error end)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    assert Game.get_server_state(game_id).action_count == 15
    assert {:ok, ^p1, _} = Game.attach(game_id, g1, self())
    assert {:finished, _} = Oskol.Bots.play(game_id, 10, 5000)
  end

  test "rehydration restores the clock and resumes it paused-until-now" do
    %{game_id: game_id, p1: p1, mover: mover} = started(42, "single", clock: "bg3")
    action = legal_move(game_id |> Game.get_server_state() |> Map.get(:instance), mover)
    {:ok, _, _} = Game.player_action(game_id, mover, action)

    remaining_before = remaining(game_id, p1)

    Persister.flush()
    kill_room(game_id)
    assert {:ok, _pid} = Game.lookup_game(game_id)

    state = Game.get_server_state(game_id)
    update = GameKit.player_update(state.instance, p1)
    assert update["clock"]["enabled"]
    # Nobody was charged for the downtime: remaining time is what it was at
    # the last applied action (within the wall-clock slack of this test).
    assert_in_delta remaining(game_id, p1), remaining_before, 2_000
    # And the clock is running again: the room has a next deadline.
    assert {:ok, ms} = GameKit.next_deadline(state.instance)
    assert ms > 0
  end

  test "a room made under a clock that is no longer offered still rehydrates with it" do
    # Blitz was one of backgammon's clocks before the home page offered 3, 5
    # and 10 minutes. It is still defined, so rooms that picked it replay.
    %{game_id: game_id, p1: p1, mover: mover} = started(42, "single", clock: "bg3")
    action = legal_move(game_id |> Game.get_server_state() |> Map.get(:instance), mover)
    {:ok, _, _} = Game.player_action(game_id, mover, action)

    Persister.flush()
    kill_room(game_id)

    game = Repo.get!(Persistence.Game, game_id)

    game
    |> Ecto.Changeset.change(config: Map.put(game.config, "clock", "blitz"))
    |> Repo.update!()

    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    assert state.setup.clock == "blitz"
    assert state.action_count == 1

    assert GameKit.player_update(state.instance, p1)["clock"]["label"] ==
             "3 min + 2 s, 12 s delay every turn"
  end

  test "a creator cannot pick a retired clock; a room that has one keeps it" do
    %{game_id: game_id} = lobby("single")
    assert {:error, :unknown_clock} = Game.configure(game_id, %{clock: "blitz"})

    state = Game.get_server_state(game_id)
    assert {:error, :unknown_clock} = GameServerState.validate_setup(state, %{clock: "blitz"})

    assert {:ok, %{clock: "blitz"}} =
             GameServerState.validate_setup(state, %{clock: "blitz"}, retired_clocks: true)

    assert {:error, :unknown_clock} =
             GameServerState.validate_setup(state, %{clock: "hourglass"}, retired_clocks: true)
  end

  defp remaining(game_id, viewer) do
    state = Game.get_server_state(game_id)

    GameKit.player_update(state.instance, viewer)["clock"]["players"]
    |> Enum.map(& &1["remaining_ms"])
    |> Enum.sum()
  end

  test "pruning deletes idle unfinished games and their actions, keeps finished ones" do
    old = DateTime.add(DateTime.utc_now(), -4 * 86_400, :second)
    stale = insert_game("stale", "playing", old)
    Repo.insert!(%Persistence.GameAction{game_id: stale, index: 0, kind: "action", at_ms: 0})
    done = insert_game("done", "finished", old)
    fresh = insert_game("fresh", "playing", DateTime.utc_now())

    assert Pruner.prune_now() == 1

    assert Repo.get(Persistence.Game, stale) == nil
    assert Repo.get_by(Persistence.GameAction, game_id: stale) == nil
    assert Repo.get(Persistence.Game, done)
    assert Repo.get(Persistence.Game, fresh)
  end

  defp insert_game(prefix, status, updated_at) do
    id = unique_game_id(prefix)
    Repo.insert!(%Persistence.Game{id: id, slug: "backgammon", status: status})

    import Ecto.Query

    from(g in Persistence.Game, where: g.id == ^id)
    |> Repo.update_all(set: [updated_at: updated_at])

    id
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
