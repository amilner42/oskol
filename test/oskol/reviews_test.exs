defmodule Oskol.ReviewsTest do
  @moduledoc """
  The review pipeline's wiring: a room that finishes a backgammon game asks
  the queue, the queue replays the log and calls the engine (a Req.Test
  stub, never the network), the answer is stored per game, and the /papi
  endpoint reads it. What a review is and when one is owed is tested in
  Gleam (test/oskol/reviews_handler_test.gleam).
  """
  # Rooms, the persister and the queue's tasks all touch the database from
  # their own processes: shared sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game.Persister
  alias Oskol.Repo
  alias Oskol.Reviews
  alias Oskol.Reviews.Queue

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:oskol, Queue)
    Application.put_env(:oskol, Queue, enabled: true)

    on_exit(fn ->
      Queue.await_idle()
      Queue.reset()
      Application.put_env(:oskol, Queue, previous)
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # An engine that grades the opening turn best and every turn after it as
  # a mistake worth 0.05 -- so this, the only end-to-end run, really crosses
  # the puzzle-extraction seam -- and counts the requests it gets.
  # Everything the stub has reported so far, thrown away.
  defp drain_engine_calls do
    receive do
      {:engine, _} -> drain_engine_calls()
    after
      0 -> :ok
    end
  end

  defp engine(test_pid) do
    Req.Test.stub(Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      request = Jason.decode!(body)
      send(test_pid, {:engine, request})
      Req.Test.json(conn, answer(length(request["turns"])))
    end)
  end

  defp answer(n) do
    candidate = fn rank, diff ->
      %{
        "rank" => rank,
        "notation" => "13/10 6/5",
        "board" => [],
        "equity" => 0.1,
        "cubeless_equity" => 0.1,
        "equity_diff" => diff,
        "probs" => %{
          "win" => 0.5,
          "gammon_win" => 0.1,
          "backgammon_win" => 0.0,
          "gammon_loss" => 0.1,
          "backgammon_loss" => 0.0
        }
      }
    end

    totals = %{
      "moves" => %{"decisions" => n, "forced" => 0, "error" => 0.1, "grades" => %{"ok" => n}},
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.0,
      "error" => 0.1,
      "pr" => 4.2
    }

    # The opening turn is played perfectly; everything after it gives up
    # 0.05, which is a mistake and so a puzzle.
    move = fn
      0 ->
        %{
          "played" => candidate.(1, 0.0),
          "best" => candidate.(1, 0.0),
          "top" => [candidate.(1, 0.0)],
          "n_legal" => 4,
          "forced" => false,
          "error" => 0.0,
          "grade" => "best"
        }

      _ ->
        %{
          "played" => candidate.(2, -0.05),
          "best" => candidate.(1, 0.0),
          "top" => [candidate.(1, 0.0), candidate.(2, -0.05)],
          # `all_results`: one entry per legal play, which is what lets a
          # puzzle grade any answer instead of shrugging at one outside the
          # top five.
          "results" =>
            for r <- 1..4 do
              %{"board" => [], "equity_diff" => -0.01 * r}
            end,
          "n_legal" => 4,
          "forced" => false,
          "error" => 0.05,
          "grade" => "doubtful"
        }
    end

    %{
      "turns" =>
        for i <- 0..(n - 1) do
          %{
            "index" => i,
            "cube" => nil,
            "move" => move.(i),
            "luck" => %{"luck" => 0.1}
          }
        end,
      "players" => [totals, totals]
    }
  end

  defp finished_game(seed) do
    %{game_id: game_id} = started(seed, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, seed, 3000)
    game_id
  end

  # The guest holding one of the room's seats: reading a review is open to
  # anyone, but only a player's visit queues one.
  defp seat_guest(game_id) do
    state = Oskol.Game.get_server_state(game_id)
    [{player, _name} | _] = Oskol.Game.GameServerState.seats(state)
    Oskol.GameFixtures.guest_for(game_id, player)
  end

  # The room casts the queue as the game ends; wait for the job to land.
  defp wait_for(fun, tries \\ 200) do
    Queue.await_idle()

    case fun.() do
      result when result in [nil, false, []] and tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      result ->
        result
    end
  end

  # Commit exactly one turn without letting the generic random bot choose
  # cube, resignation, undo, or any other legal action added by a game UI.
  defp play_one_turn(game_id, player_id) do
    state = Oskol.Game.get_server_state(game_id)
    legal = Oskol.GameKit.legal(state.instance, player_id)

    schema =
      Enum.find(legal, &(&1["name"] == "play")) ||
        Enum.find(legal, &(&1["name"] == "move"))

    assert schema
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, player_id, Oskol.Bots.action(schema))

    if schema["name"] == "move", do: play_one_turn(game_id, player_id)
  end

  defp finish_one_game(game_id, p1, p2) do
    first = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
    play_one_turn(game_id, first)
    first = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
    second = if first == p1, do: p2, else: p1

    assert {:ok, _, _} =
             Oskol.Game.player_action(game_id, first, %{
               "name" => "resign",
               "params" => %{"stakes" => "single"}
             })

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, second, simple("accept_resign"))
    Persister.flush()
  end

  defp read_queries(fun) do
    id = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:oskol, :repo, :query],
        fn _, _, meta, {pid, tag} ->
          send(pid, {tag, meta.query})
        end,
        {parent, id}
      )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_queries(id, [])
  end

  defp drain_queries(id, queries) do
    receive do
      {^id, query} -> drain_queries(id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp reviews(conn, game_id) do
    conn
    |> as_guest(seat_guest(game_id))
    |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
    |> json_response(200)
  end

  defp review(conn, game_id, number) do
    conn
    |> as_guest(seat_guest(game_id))
    |> get("/papi/games/backgammon/rooms/#{game_id}/reviews/#{number}")
    |> json_response(200)
  end

  test "a finished game is reviewed off the room and the endpoint serves it", %{conn: conn} do
    engine(self())
    game_id = finished_game(5)

    [row] = wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "done")) end)
    assert row.game_number == 1
    assert row.attempts == 1
    assert_received {:engine, %{"turns" => [%{"board" => board} | _], "jacoby" => false}}

    assert board == [
             0,
             -2,
             0,
             0,
             0,
             0,
             5,
             0,
             3,
             0,
             0,
             0,
             -5,
             5,
             0,
             0,
             0,
             -3,
             0,
             -5,
             0,
             0,
             0,
             0,
             2,
             0
           ]

    # The rendered answer is written down with the engine's own, so the row
    # a read is served out of is already there.
    assert row.turns > 0
    assert is_map(Reviews.report(game_id, 1))
    assert Reviews.records(game_id) |> Enum.map(& &1.game_number) == [1]

    body = reviews(conn, game_id)
    assert body["ok"] == true
    assert [%{"name" => "Alice", "color" => "white"}, %{"name" => "Bob"}] = body["players"]
    # The index names the games and nothing else: a few hundred bytes, so a
    # page can ask for it as often as it likes.
    assert [%{"game_number" => 1, "status" => "done", "turns" => turns}] = body["games"]
    assert turns == row.turns
    refute Map.has_key?(hd(body["games"]), "review")
    assert byte_size(Jason.encode!(body)) < 400

    one = review(conn, game_id, 1)
    assert %{"game_number" => 1, "status" => "done", "review" => review} = one

    assert [%{"pr" => 4.2, "moves" => %{"grades" => %{"ok" => _, "best" => 0}}}, _] =
             review["players"]

    assert [%{"number" => 1, "move" => %{"grade" => "best"}, "luck" => 0.1} | _] =
             review["turns"]

    # And the mistakes the engine found crossed into the puzzle tables
    # through the real capability -- the one place the Gleam record and its
    # Elixir tuple twin are checked against each other for real.
    sources = Repo.all(from(s in Oskol.Puzzles.Source, where: s.game_id == ^game_id))
    assert length(sources) > 0
    assert Enum.all?(sources, &(&1.kind == "move"))
    assert Enum.all?(sources, &(&1.equity_lost == 0.05))
    assert Enum.all?(sources, &(&1.grade == "doubtful"))
    assert Enum.all?(sources, &(&1.game_number == 1))
    # The opening turn was played best, so nothing is asked about it.
    refute Enum.any?(sources, &(&1.turn == 1))

    ids = sources |> Enum.map(& &1.puzzle_id) |> Enum.reject(&is_nil/1)
    assert length(ids) == length(sources)
    puzzles = Repo.all(from(p in Oskol.Puzzles.Puzzle, where: p.id in ^ids))
    assert length(puzzles) == length(Enum.uniq(ids))

    for puzzle <- puzzles do
      assert String.length(puzzle.id) == 8
      assert puzzle.kind == "move"
      assert [_ | _] = puzzle.question["board"]
      assert [_, _] = puzzle.question["dice"]
      # The engine sent a result for every legal play, so the answer says
      # it is complete and holds all four -- not only the five described.
      assert puzzle.answer["complete"] == true
      assert puzzle.answer["n_legal"] == 4
      assert length(puzzle.answer["outcomes"]) == 4
      assert Enum.all?(puzzle.answer["outcomes"], &(&1["equity_lost"] > 0))
    end

    # And each one's link picture was drawn in the same job, right after
    # the store, through the real `pictures` capability (the test binary
    # answers a PNG for any SVG).
    for puzzle <- puzzles do
      assert {:ok, <<0x89, "PNG", _::binary>>} = Oskol.Puzzles.Pictures.png(puzzle.id)
      assert Repo.get(Oskol.Puzzles.Image, puzzle.id).attempts == 1
    end

    refute Oskol.Puzzles.Pictures.any_owed?()

    # Extracted, so the minute sweep has nothing more to do here.
    assert Oskol.Puzzles.unextracted(game_id) == []

    # A game the room does not have is not there
    assert conn
           |> get("/papi/games/backgammon/rooms/#{game_id}/reviews/7")
           |> json_response(404)

    # Already done: asking again runs nothing
    Queue.enqueue(game_id)
    Queue.await_idle()
    refute_received {:engine, _}
  end

  test "reading a game nobody analysed queues nothing, and writes its record down",
       %{conn: conn} do
    # Finished with the queue off, as every game finished before the
    # pipeline existed was. Reading it says pending and puts nobody to
    # work; catching those games up is the operator's job, not a reader's.
    Application.put_env(:oskol, Queue, enabled: false)
    game_id = finished_game(6)
    Persister.flush()
    engine(self())

    assert [%{"status" => "pending", "game_number" => 1}] = reviews(conn, game_id)["games"]
    assert %{"status" => "pending", "review" => nil} = review(conn, game_id, 1)
    refute_received {:engine, _}

    # ...but the one read it took to find that out was paid for: the room's
    # record is written down, so no read after it replays the log.
    assert Reviews.records(game_id) |> Enum.map(& &1.game_number) == [1]

    # And the queue, asked for the room the way an operator asks, finishes it.
    Application.put_env(:oskol, Queue, enabled: true)
    Queue.enqueue(game_id)
    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    assert [%{"status" => "done"}] = reviews(conn, game_id)["games"]
    assert %{"review" => %{"turns" => [_ | _]}} = review(conn, game_id, 1)
  end

  test "a stored room is read with no replay and no room", %{conn: _conn} do
    engine(self())
    game_id = finished_game(5)
    wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "done")) end)
    Persister.flush()

    # Stop the room. A read of a settled room must not bring it back: a
    # rehydration replays the whole action log, which is what took
    # production down.
    {:ok, pid} = Oskol.Game.GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Oskol.Game.GameSupervisor, pid)
    # The room is off the registry a moment after it dies, not the instant
    # terminate_child returns: asserting straight away failed one run in
    # three.
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    wait_for(fn -> Oskol.Game.GameSupervisor.find_game(game_id) == :error end)

    # Reads are open, so nothing here needs the room to say who anyone is.
    index =
      build_conn()
      |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
      |> json_response(200)

    assert [%{"status" => "done"}] = index["games"]
    assert Oskol.Game.GameSupervisor.find_game(game_id) == :error
    assert [_] = Reviews.records(game_id)

    one =
      build_conn()
      |> get("/papi/games/backgammon/rooms/#{game_id}/reviews/1")
      |> json_response(200)

    assert %{"review" => %{"turns" => [_ | _]}} = one
    assert Oskol.Game.GameSupervisor.find_game(game_id) == :error

    body =
      build_conn()
      |> get("/papi/games/backgammon/rooms/#{game_id}/record")
      |> json_response(200)

    assert [%{"number" => 1, "entries" => [_ | _]}] = body["record"]["games"]
    assert [%{"name" => "Alice"}, %{"name" => "Bob"}] = body["record"]["players"]
    assert Oskol.Game.GameSupervisor.find_game(game_id) == :error
  end

  test "ordinary next-game play leaves index/detail reads independent of logs and record bodies" do
    engine(self())
    %{game_id: game_id, p1: p1, p2: p2} = started(2, "match3")
    finish_one_game(game_id, p1, p2)
    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    Queue.await_idle()

    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p1, simple("ready"))
    assert {:ok, _, _} = Oskol.Game.player_action(game_id, p2, simple("ready"))
    first = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
    play_one_turn(game_id, first)
    Persister.flush()

    queries =
      read_queries(fn ->
        assert %{"games" => [%{"game_number" => 1, "status" => "done"}]} =
                 build_conn()
                 |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
                 |> json_response(200)

        assert %{"review" => %{"turns" => [_ | _]}} =
                 build_conn()
                 |> get("/papi/games/backgammon/rooms/#{game_id}/reviews/1")
                 |> json_response(200)
      end)

    assert queries != []
    refute Enum.any?(queries, &String.contains?(&1, "game_actions"))
    refute Enum.any?(queries, &String.contains?(&1, ~s(."entries")))
  end

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

  # Waits out the retry backoffs on purpose: seconds of sleeping, not work.
  @tag :slow
  test "an engine that fails is recorded and the game stays pending", %{conn: conn} do
    Req.Test.stub(Reviews, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"detail" => "turns[3]: bad"})
    end)

    game_id = finished_game(7)

    [row] = wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "failed")) end)
    assert row.attempts == 1
    assert row.error =~ "HTTP 422"
    # A retry is still to come (after the backoff), so the page waits
    assert [%{"status" => "pending"}] = reviews(conn, game_id)["games"]
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

  test "the engine client never raises" do
    Req.Test.stub(Reviews, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, reason} = Reviews.request("{}")
    assert reason =~ "refused"

    Req.Test.stub(Reviews, &Plug.Conn.send_resp(&1, 200, "{\"turns\":[]}"))
    assert {:ok, "{\"turns\":[]}"} = Reviews.request("{}")
  end

  test "a legacy turn-count backfill preserves a newer failed review" do
    game_id = "turn-count-backfill"
    :ok = Oskol.Persistence.insert_game(game_id, "backgammon", %{})

    :ok = Reviews.save(game_id, 1, "failed", 3, nil, "engine was down", nil, 0)
    :ok = Reviews.backfill_turns(game_id, 1, 42)

    assert [%{game_number: 1, status: "failed", attempts: 3, error: "engine was down", turns: 42}] =
             Reviews.stored(game_id)
  end

  test "only started backgammon rooms have reviews", %{conn: conn} do
    assert conn |> get("/papi/games/backgammon/rooms/999999/reviews?t=x") |> json_response(404)
    assert conn |> get("/papi/games/poker/rooms/999999/reviews?t=x") |> json_response(404)
  end

  test "a room's reviews open to anyone with the room, token or not", %{conn: conn} do
    engine(self())
    game_id = finished_game(5)
    wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "done")) end)

    seated = reviews(conn, game_id)
    assert %{"games" => [_ | _]} = seated

    # The analysis of a finished game is nobody's secret: a shared replay
    # link reads it with no token, or with one that opens no seat.
    for query <- ["", "?t=", "?t=not-a-token"] do
      assert build_conn()
             |> get("/papi/games/backgammon/rooms/#{game_id}/reviews#{query}")
             |> json_response(200) == seated
    end
  end
end
