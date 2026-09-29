defmodule Oskol.ReviewsTest do
  @moduledoc """
  What the `/papi` endpoint serves once a room has been reviewed: the index
  and the detail, what a read costs in queries, and who is allowed one. The
  pipeline that puts an answer there is set up in `Oskol.ReviewsCase`; how it
  survives interruption is in `reviews_recovery_test.exs`, and the engine
  client itself in `reviews_engine_test.exs`. What a review *is* and when one
  is owed is tested in Gleam (test/oskol/reviews_handler_test.gleam).
  """
  use Oskol.ReviewsCase

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
