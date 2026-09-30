defmodule Oskol.Reviews.RecoveryTest do
  @moduledoc """
  The queue when something interrupts it: a task killed while its job is
  pending, a job lost to a restart and found again by the sweep at boot, a
  game that ends while the room it belongs to is already being reviewed, and
  a record checkpoint that must not settle a game that ended during the
  replay. The sweep is idempotent by design -- a stale note buys no second
  analysis -- and that is the property most of this file is about.
  """
  use Oskol.ReviewsCase

  test "a captured record checkpoint cannot settle a game that ended during replay" do
    Application.put_env(:oskol, Queue, enabled: false)
    %{game_id: game_id, p1: p1, p2: p2} = started(2, "match3")
    finish_one_game(game_id, p1, p2)

    assert %{"games" => [%{"game_number" => 1}]} =
             build_conn()
             |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
             |> json_response(200)

    old = Reviews.log(game_id)
    generation = Reviews.record_generation(old.game)
    rows = Enum.map(Reviews.records(game_id), &{&1.game_number, &1.entries})

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p1, simple("ready"))
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p2, simple("ready"))
    finish_one_game(game_id, p1, p2)
    assert Reviews.record_generation(Reviews.setup(game_id)) > generation

    :ok = Reviews.save_records(game_id, rows, length(old.actions), generation)
    {:records_caps, setup, _, _, _, _} = Oskol.Gleam.Caps.Records.build()
    assert {:some, {:setup, _, _, _, _, _, _, true}} = setup.(game_id)

    assert %{"games" => [%{"game_number" => 1}, %{"game_number" => 2}]} =
             build_conn()
             |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
             |> json_response(200)

    newer = Reviews.setup(game_id).records_generation
    :ok = Reviews.save_records(game_id, rows, length(old.actions), generation)
    assert Reviews.setup(game_id).records_generation == newer
    assert {:some, {:setup, _, _, _, _, _, _, false}} = setup.(game_id)
  end

  test "a task killed while pending is recovered without a queue restart" do
    parent = self()

    Req.Test.stub(Reviews, fn _conn ->
      send(parent, {:held_analysis, self()})

      receive do
        :release -> raise "test should kill the held task"
      end
    end)

    %{game_id: game_id, p1: p1, p2: p2} = started(2, "match3")
    finish_one_game(game_id, p1, p2)
    assert_receive {:held_analysis, task}, 10_000
    queue = Process.whereis(Queue)
    assert [^game_id] = Reviews.rooms_owed_analysis()

    # Recovery scanning must not duplicate running work.
    Queue.sweep_owed()
    assert :sys.get_state(queue).again == MapSet.new()
    refute_received {:held_analysis, _}

    Process.exit(task, :kill)
    Queue.await_idle()
    assert [%{status: "pending", attempts: 1}] = Reviews.summaries(game_id)
    assert Process.whereis(Queue) == queue

    engine(self())
    # A sweep during crash backoff must leave the interrupted attempt alone.
    Queue.sweep_owed()
    Queue.await_idle()
    assert [%{status: "pending", attempts: 1}] = Reviews.summaries(game_id)
    refute_received {:engine, _}

    :sys.replace_state(queue, fn state ->
      put_in(state, [:crashes, game_id, :retry_at], System.monotonic_time(:millisecond) - 1)
    end)

    # The same scan the periodic timer calls after backoff, no restart/read.
    Queue.sweep_owed()
    Queue.await_idle()
    assert [%{status: "done", attempts: 2}] = Reviews.summaries(game_id)
    assert Reviews.rooms_owed_analysis() == []
    refute Map.has_key?(:sys.get_state(queue).crashes, game_id)
    assert_receive {:engine, _}
    refute_received {:engine, _}
  end

  test "a job lost to a restart is picked up by the sweep at boot", %{conn: conn} do
    # The queue lives in memory: a machine that restarts between a game
    # ending and its job running forgets the job. Nothing else would ever
    # pick it up, because a read never queues engine work. What survives is
    # the note the room wrote before it asked.
    Application.put_env(:oskol, Queue, enabled: false)
    game_id = finished_game(7)
    Persister.flush()
    Oskol.Reviews.mark_analysis_owed(game_id)
    Application.put_env(:oskol, Queue, enabled: true)
    engine(self())

    assert [%{"status" => "pending"}] = reviews(conn, game_id)["games"]
    assert [^game_id] = Oskol.Reviews.rooms_owed_analysis()

    assert Queue.sweep_owed() == 1
    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    assert [%{"status" => "done"}] = reviews(conn, game_id)["games"]

    # And the note is gone, so the next boot does not look again.
    Queue.await_idle()
    assert Oskol.Reviews.rooms_owed_analysis() == []
  end

  test "a game that ends while a job is running keeps its note", %{conn: _conn} do
    # The job read the log before that game existed, so it cannot have
    # analysed it. Clearing the note on the way out would lose it, and
    # nothing else would ever look: a read does not queue engine work.
    engine(self())
    game_id = finished_game(9)
    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    Queue.await_idle()
    assert Oskol.Reviews.rooms_owed_analysis() == []

    # What a job that started before this note would try to clear.
    before = DateTime.add(DateTime.utc_now(), -60, :second)
    Oskol.Reviews.mark_analysis_owed(game_id)
    Oskol.Reviews.clear_analysis_owed(game_id, before)

    assert [^game_id] = Oskol.Reviews.rooms_owed_analysis()

    # A recovery pass that saw no note must not erase a later completion.
    Oskol.Reviews.clear_analysis_owed(game_id, nil)

    assert [^game_id] = Oskol.Reviews.rooms_owed_analysis()

    # A job that has seen this note may clear it.
    Oskol.Reviews.clear_analysis_owed(game_id, Oskol.Reviews.analysis_owed_at(game_id))
    assert Oskol.Reviews.rooms_owed_analysis() == []
  end

  test "the sweep never analyses a game twice", %{conn: conn} do
    engine(self())
    game_id = finished_game(8)
    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    assert [%{"status" => "done"}] = reviews(conn, game_id)["games"]

    # The engine calls from that first, legitimate analysis are still in
    # this process's mailbox; clear them so what follows is only what the
    # sweep caused.
    drain_engine_calls()

    # A stale note -- the room was marked, the work happened anyway -- must
    # not buy a second analysis for a game that already has one.
    Oskol.Reviews.mark_analysis_owed(game_id)
    assert Queue.sweep_owed() == 1
    Queue.await_idle()

    refute_received {:engine, _}
    assert [%{"status" => "done"}] = reviews(conn, game_id)["games"]
    assert length(Reviews.stored(game_id)) == 1
  end

  test "a game that ends while its room is being reviewed is reviewed too", %{conn: conn} do
    # The engine holds the first request until the whole match is over, so
    # the job for game 1 read the log before game 2 ended. The room's
    # enqueue for game 2 lands while that job runs; it must run again.
    test_pid = self()
    :persistent_term.put({__MODULE__, :held}, false)

    Req.Test.stub(Reviews, fn conn ->
      if not :persistent_term.get({__MODULE__, :held}) do
        :persistent_term.put({__MODULE__, :held}, true)
        send(test_pid, {:holding, self()})

        receive do
          :go -> :ok
        end
      end

      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      Req.Test.json(conn, answer(length(Jason.decode!(body)["turns"])))
    end)

    %{game_id: game_id, p1: p1, p2: p2} = started(2, "match3")
    state = Oskol.Game.get_server_state(game_id)
    first = mover(state.instance, [p1, p2])
    play_one_turn(game_id, first)
    state = Oskol.Game.get_server_state(game_id)
    first = mover(state.instance, [p1, p2])
    second = if first == p1, do: p2, else: p1

    assert {:ok, _, _} =
             Oskol.Game.player_action(game_id, first, %{
               "name" => "resign",
               "params" => %{"stakes" => "single"}
             })

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, second, simple("accept_resign"))
    assert_receive {:holding, engine}, 10_000

    # End the next game while the first game's engine request is held. This
    # is deliberate rather than a seeded bot path: adding an unrelated legal
    # action must not change how many games this queue race exercises.
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p1, simple("ready"))
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p2, simple("ready"))
    state = Oskol.Game.get_server_state(game_id)
    first = mover(state.instance, [p1, p2])
    play_one_turn(game_id, first)
    state = Oskol.Game.get_server_state(game_id)
    first = mover(state.instance, [p1, p2])
    second = if first == p1, do: p2, else: p1

    assert {:ok, _, _} =
             Oskol.Game.player_action(game_id, first, %{
               "name" => "resign",
               "params" => %{"stakes" => "single"}
             })

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, second, simple("accept_resign"))
    send(engine, :go)

    # Read the table, not the endpoint: a request would queue what is owed
    # by itself and hide a lost enqueue.
    done =
      wait_for(fn ->
        rows = Enum.filter(Reviews.stored(game_id), &(&1.status == "done"))
        if length(rows) >= 2, do: rows
      end)

    assert Enum.map(done, & &1.game_number) == [1, 2]
    assert Enum.all?(reviews(conn, game_id)["games"], &(&1["status"] in ["done", "empty"]))
  end
end
