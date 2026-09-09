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

  test "a game in play rehydrates mid-game: same view, same tokens, play continues to a finish" do
    %{game_id: game_id, p1: p1, p2: p2, t1: t1, t2: t2} = started(42)
    assert {:cut_off, 20} = Oskol.Bots.play(game_id, 7, 20)

    before = Game.get_server_state(game_id)
    view_before = GameKit.player_update(before.instance, p1) |> Map.take(["scene", "legal"])

    Persister.flush()
    kill_room(game_id)

    # The lookup any entry point uses (invite link, token URL, JOIN GAME
    # code, channel join) rehydrates the room.
    assert {:ok, _pid} = Game.lookup_game(game_id)

    state = Game.get_server_state(game_id)
    assert state.action_count == 20
    assert GameServerState.token_for(state, p1) == t1
    assert GameServerState.token_for(state, p2) == t2
    assert GameServerState.seats(state) == GameServerState.seats(before)

    # Replay is exact: the rehydrated instance projects the same scene and
    # offers the same legal actions.
    assert GameKit.player_update(state.instance, p1) |> Map.take(["scene", "legal"]) ==
             view_before

    # Both players' token URLs still open their seats.
    assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())
    assert {:ok, ^p2, _} = Game.attach(game_id, t2, self())

    # And the game plays on to a finish, persisted as such.
    assert {:finished, more} = Oskol.Bots.play(game_id, 8, 5000)
    Persister.flush()
    row = Repo.get(Persistence.Game, game_id)
    assert row.status == "finished"
    assert length(Repo.all(Persistence.GameAction)) >= 20 + more
  end

  test "a waiting room rehydrates: the seat holds, and the game starts when the table fills" do
    %{game_id: game_id, p1: p1, t1: t1} = lobby("single", seed: 42)

    Persister.flush()
    kill_room(game_id)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    refute GameServerState.started?(state)
    assert GameServerState.token_for(state, p1) == t1
    assert state.setup.format == "single"

    {:ok, _p2, joined} = Game.join_game(game_id, "Bob", nil)
    assert GameServerState.started?(joined)
    assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())
  end

  test "a finished game rehydrates read-only: final position, no further actions" do
    %{game_id: game_id, p1: p1, t1: t1} = started(42)
    assert {:finished, _} = Oskol.Bots.play(game_id, 7, 5000)

    Persister.flush()
    kill_room(game_id)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    assert GameKit.finished?(state.instance)

    # The token still shows the table (and would offer a rematch)...
    assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())
    # ...but the engine refuses further play.
    assert {:error, _} = Game.player_action(game_id, p1, simple("roll"))
  end

  test "a code with no live room and no row stays not found" do
    assert Game.lookup_game(unique_game_id("ghost")) == :not_found
  end

  test "deploy simulation: the whole room supervisor restarts and a half-played game carries on" do
    %{game_id: game_id, p1: p1, t1: t1} = started(42)
    assert {:cut_off, 15} = Oskol.Bots.play(game_id, 9, 15)
    Persister.flush()

    # A deploy: every room process dies with its supervisor.
    :ok = Supervisor.terminate_child(Oskol.Supervisor, GameSupervisor)
    {:ok, _} = Supervisor.restart_child(Oskol.Supervisor, GameSupervisor)
    # Registry sweeps dead rooms asynchronously; wait for the entry to clear.
    wait_until(fn -> GameSupervisor.find_game(game_id) == :error end)

    assert {:ok, _pid} = Game.lookup_game(game_id)
    assert Game.get_server_state(game_id).action_count == 15
    assert {:ok, ^p1, _} = Game.attach(game_id, t1, self())
    assert {:finished, _} = Oskol.Bots.play(game_id, 10, 5000)
  end

  test "rehydration restores the clock and resumes it paused-until-now" do
    %{game_id: game_id, p1: p1, mover: mover} = started(42, "single", clock: "blitz")
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
