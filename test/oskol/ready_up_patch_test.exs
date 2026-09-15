defmodule Oskol.ReadyUpPatchTest do
  # Rooms and the persister write from their own processes: shared sandbox,
  # not async.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game
  alias Oskol.Game.{GameSupervisor, Persister, ReadyUpPatch}
  alias Oskol.GameKit
  alias Oskol.Persistence
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

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

  defp rows(game_id) do
    Persister.flush()

    from(a in Persistence.GameAction, where: a.game_id == ^game_id, order_by: a.index)
    |> Repo.all()
  end

  defp ready?(row), do: row.kind == "action" and row.payload["name"] == "ready"

  # The log as the engine wrote it before READY existed: the same steps with
  # every `ready` gone (ready spends no randomness, so what is left is
  # exactly the log the old engine would have written for this play).
  defp strip_readies(game_id) do
    kept = rows(game_id) |> Enum.reject(&ready?/1)

    Repo.transaction(fn ->
      from(a in Persistence.GameAction, where: a.game_id == ^game_id) |> Repo.delete_all()

      kept
      |> Enum.with_index()
      |> Enum.each(fn {row, index} ->
        Repo.insert!(%Persistence.GameAction{
          game_id: game_id,
          index: index,
          kind: row.kind,
          player_id: row.player_id,
          payload: row.payload,
          at_ms: row.at_ms
        })
      end)
    end)

    kept
  end

  defp report_for(reports, game_id), do: Enum.find(reports, &(&1.game_id == game_id))

  defp view(game_id, player_id) do
    GameKit.player_update(Game.get_server_state(game_id).instance, player_id)
    |> Map.take(["scene", "legal"])
  end

  defp phase(game_id, player_id), do: view(game_id, player_id)["scene"]["phase"]

  defp game_number(game_id, player_id),
    do: view(game_id, player_id)["scene"]["data"]["game_number"]

  # Random legal play, one step at a time, until `done?` holds.
  defp play_until(game_id, done?, step \\ 0) do
    cond do
      done?.() ->
        :ok

      step > 20_000 ->
        flunk("position not reached")

      true ->
        {:cut_off, 1} = Oskol.Bots.play(game_id, 1000 + step, 1)
        play_until(game_id, done?, step + 1)
    end
  end

  test "an old-style unlimited log is patched, rehydrates where it was, and plays on" do
    %{game_id: game_id, p1: p1, p2: p2} = started(42, "unlimited")

    # Two games over and a third under way, not parked on a pause.
    play_until(game_id, fn ->
      game_number(game_id, p1) >= 3 and phase(game_id, p1) != "between_games"
    end)

    {:cut_off, 5} = Oskol.Bots.play(game_id, 3, 5)

    play_until(game_id, fn -> phase(game_id, p1) != "between_games" end)

    before = %{p1 => view(game_id, p1), p2 => view(game_id, p2)}
    readies = rows(game_id) |> Enum.filter(&ready?/1) |> length()
    assert readies >= 4

    old_log = strip_readies(game_id)
    kill_room(game_id)

    # Unpatched, the old log no longer replays: the first move of the next
    # game is refused at the pause, and the room cannot come back.
    assert Game.lookup_game(game_id) == :not_found

    # A dry run says what it would do and writes nothing.
    dry = ReadyUpPatch.run() |> report_for(game_id)
    assert dry.result == :would_patch
    assert length(dry.inserts) == readies
    assert rows(game_id) |> length() == length(old_log)

    # Both seats' readies go in before the entry the pause refused, in seat
    # order, stamped with the time of the step that ended the game.
    [first, second | _] = dry.inserts
    assert first.before_index == second.before_index
    assert [first.player_id, second.player_id] == [p1, p2]
    ended = Enum.at(old_log, first.before_index - 1)
    assert first.at_ms == ended.at_ms

    written = ReadyUpPatch.run(write: true) |> report_for(game_id)
    assert written.result == :patched
    patched = rows(game_id)
    assert length(patched) == length(old_log) + readies
    assert Enum.map(patched, & &1.index) == Enum.to_list(0..(length(patched) - 1))

    assert {:ok, _pid} = Game.lookup_game(game_id)
    assert view(game_id, p1) == before[p1]
    assert view(game_id, p2) == before[p2]

    # Idempotent: a second run finds nothing to do.
    assert (ReadyUpPatch.run(write: true) |> report_for(game_id)).result == :unchanged
    assert rows(game_id) |> length() == length(patched)

    # And the room plays on, pausing between games like any new one.
    play_until(game_id, fn -> phase(game_id, p1) == "between_games" end)
    {:ok, _, _} = Game.player_action(game_id, p1, simple("ready"))
    {:ok, _, _} = Game.player_action(game_id, p2, simple("ready"))
    assert phase(game_id, p1) != "between_games"
  end

  # Logs the old engine really wrote: golden replays recorded before READY
  # existed, with the scene each seat saw at their end. Patched and
  # rehydrated, the room shows each seat exactly that scene.
  for name <- ~w(backgammon-match3-1 backgammon-match7-1 backgammon-unlimited-1) do
    test "a log the old engine wrote (#{name}) patches to the very position it recorded" do
      fixture =
        Path.join([File.cwd!(), "test/fixtures/pre_ready_logs", unquote(name) <> ".json"])
        |> File.read!()
        |> Jason.decode!()

      game_id = unique_game_id("legacy")
      seats = fixture["seats"]

      Repo.insert!(%Persistence.Game{
        id: game_id,
        slug: "backgammon",
        config: %{
          "format" => fixture["format"],
          "selections" => %{},
          "clock" => "none",
          "seed" => fixture["seed"]
        },
        seed: fixture["seed"],
        players: Enum.map(seats, &Map.put(&1, "token", "tok-" <> &1["id"])),
        status: if(fixture["finished"], do: "finished", else: "playing")
      })

      fixture["steps"]
      |> Enum.with_index()
      |> Enum.each(fn {step, index} ->
        Repo.insert!(%Persistence.GameAction{
          game_id: game_id,
          index: index,
          kind: "action",
          player_id: step["player_id"],
          payload: Jason.decode!(step["action"]),
          at_ms: 0
        })
      end)

      assert Game.lookup_game(game_id) == :not_found

      report = ReadyUpPatch.run(write: true) |> report_for(game_id)
      assert report.result == :patched
      assert report.inserts != []

      assert {:ok, _pid} = Game.lookup_game(game_id)
      state = Game.get_server_state(game_id)
      assert GameKit.finished?(state.instance) == fixture["finished"]

      recorded = fixture["fingerprint"] |> String.split("\n") |> Enum.map(&Jason.decode!/1)

      assert Enum.map(seats, &GameKit.player_update(state.instance, &1["id"])["scene"]) ==
               recorded

      assert (ReadyUpPatch.run() |> report_for(game_id)).result == :unchanged
    end
  end

  test "a single game is never touched" do
    %{game_id: game_id} = started(42, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, 7, 5000)
    log = rows(game_id)

    assert ReadyUpPatch.run(write: true) |> report_for(game_id) == nil
    assert rows(game_id) == log
  end

  test "a room made under the new rules is left alone, paused or not" do
    %{game_id: game_id, p1: p1, p2: p2} = started(42, "match3")
    play_until(game_id, fn -> phase(game_id, p1) == "between_games" end)
    # Parked on the pause with nobody ready: waiting legitimately.
    assert (ReadyUpPatch.run(write: true) |> report_for(game_id)).result == :unchanged

    {:ok, _, _} = Game.player_action(game_id, p2, simple("ready"))
    {:ok, _, _} = Game.player_action(game_id, p1, simple("ready"))
    {:cut_off, 10} = Oskol.Bots.play(game_id, 5, 10)
    log = rows(game_id)
    assert (ReadyUpPatch.run(write: true) |> report_for(game_id)).result == :unchanged
    assert rows(game_id) == log
  end
end
