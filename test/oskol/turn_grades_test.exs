defmodule Oskol.TurnGradesTest do
  @moduledoc """
  Turns graded while the game is still being played, and the end-of-game job
  reading them as the cache they are.

  The point of the feature is what does *not* happen: no engine call for a
  turn already graded, nothing about a grade anywhere a player can reach, and
  a game with nothing cached reviewed exactly as it always was. So most of
  what is asserted here is an absence.
  """
  use Oskol.ReviewsCase

  alias Oskol.Gleam.CtxBuilder
  alias Oskol.Reviews.Grader

  setup do
    previous = Application.get_env(:oskol, Grader)
    Application.put_env(:oskol, Grader, enabled: true)

    on_exit(fn ->
      Grader.await_idle()
      Grader.reset()
      Application.put_env(:oskol, Grader, previous)
    end)

    :ok
  end

  describe "the cap" do
    test "reading grades is the review job's alone" do
      request = elem(CtxBuilder.build(), 2)
      job = elem(CtxBuilder.build(grades: true), 2)

      # Exactly one capability separates a request's context from the job's,
      # and it is the one that can see a live game has been graded at all.
      differing =
        for i <- 1..(tuple_size(request) - 1), elem(request, i) != elem(job, i), do: i

      assert [grades] = differing
      assert job |> elem(grades) |> apply(["room", 1, []]) == []
      assert catch_error(request |> elem(grades) |> apply(["room", 1, []]))
    end
  end

  describe "storage" do
    test "a grade is found by the question it answers, and only that one" do
      body = ~s({"turns":[{"index":3}]})
      other = ~s({"turns":[{"index":4}]})

      :ok = Reviews.save_turn_grade("room", 1, body, %{"turns" => [%{"index" => 3}]})

      assert [%{"turns" => [%{"index" => 3}]}, nil] =
               Reviews.turn_grades("room", 1, [body, other])

      # The same question in another game is another row.
      assert [nil] = Reviews.turn_grades("room", 2, [body])
      assert [nil] = Reviews.turn_grades("elsewhere", 1, [body])
    end

    test "a second answer to the same question is not written" do
      body = ~s({"turns":[{"index":0}]})
      :ok = Reviews.save_turn_grade("room", 1, body, %{"first" => true})
      :ok = Reviews.save_turn_grade("room", 1, body, %{"first" => false})

      assert [%{"first" => true}] = Reviews.turn_grades("room", 1, [body])
    end

    test "grades are dropped when the game's own answer is written, and by age" do
      body = ~s({"turns":[{"index":0}]})
      :ok = Reviews.save_turn_grade("room", 1, body, %{})
      :ok = Reviews.save_turn_grade("room", 2, body, %{})

      :ok = Reviews.forget_turn_grades("room", 1)
      assert [nil] = Reviews.turn_grades("room", 1, [body])
      assert [%{}] = Reviews.turn_grades("room", 2, [body])

      # A room nobody finished leaves its grades behind; the sweep has them.
      assert Reviews.sweep_turn_grades(7) == 0
      age("room", 8)
      assert Reviews.sweep_turn_grades(7) == 1
      assert [nil] = Reviews.turn_grades("room", 2, [body])
    end
  end

  describe "the grader" do
    test "asks the engine for one turn and stores the answer" do
      test_pid = self()
      engine_echoing(test_pid)

      %{game_id: game_id, p1: p1, p2: p2} = started(11, "single")
      mover = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
      play_one_turn(game_id, mover)
      Grader.await_idle()

      assert_received {:engine, request, body}
      # One turn, saying where it sits in its game -- without which the
      # engine grades every lone turn as an opening roll.
      assert [%{"index" => 0}] = request["turns"]
      # And nothing about the depth: that is the engine's own call, in one
      # place, exactly as a whole-game review leaves it.
      refute Map.has_key?(request, "move_level")

      assert [%{"turns" => [%{"index" => 0}]}] = Reviews.turn_grades(game_id, 1, [body])
    end

    test "grading the same turn twice asks the engine once" do
      test_pid = self()
      engine_echoing(test_pid)

      %{game_id: game_id, p1: p1, p2: p2} = started(12, "single")
      mover = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
      play_one_turn(game_id, mover)
      Grader.await_idle()
      assert_received {:engine, _request, body}

      # The same cast again: a rehydrated room, a duplicate, a retry.
      payload = Jason.encode!(%{"game_number" => 1, "index" => 0, "body" => body})

      Grader.grade(game_id, payload)
      Grader.await_idle()
      refute_received {:engine, _, _}
    end

    test "an engine that is not there costs one call and then nothing" do
      test_pid = self()

      Req.Test.stub(Oskol.Reviews, fn conn ->
        send(test_pid, {:engine, :asked})
        Req.Test.transport_error(conn, :econnrefused)
      end)

      %{game_id: game_id, p1: p1, p2: p2} = started(13, "single")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          mover = mover(Oskol.Game.get_server_state(game_id).instance, [p1, p2])
          play_one_turn(game_id, mover)
          Grader.await_idle()

          for index <- 1..5 do
            Grader.grade(
              game_id,
              Jason.encode!(%{
                "game_number" => 1,
                "index" => index,
                "body" => ~s({"turns":[{"index":#{index}}]})
              })
            )
          end

          Grader.await_idle()
        end)

      assert_received {:engine, :asked}
      # The circuit is open for a minute after a failure: a desktop asleep
      # behind the tailnet must not be asked once a turn by every live room.
      refute_received {:engine, :asked}
      assert log =~ "turn grading paused"
      assert Reviews.turn_grades(game_id, 1, [~s({})]) == [nil]
    end
  end

  describe "the review at the end" do
    test "asks the engine only for the turns nothing graded" do
      test_pid = self()
      engine_echoing(test_pid)

      # The queue off while the game is played, so every turn is graded
      # before the review runs -- which is what minutes of real play do on
      # their own, and what a test cannot wait for.
      Application.put_env(:oskol, Queue, enabled: false)
      game_id = finished_game(14)
      Grader.await_idle()
      Persister.flush()

      graded = Enum.count(engine_requests())
      assert graded > 5

      Application.put_env(:oskol, Queue, enabled: true)
      Queue.enqueue(game_id)
      [row] = wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "done")) end)

      # One request, for the turns the grader never saw: the one that ended
      # the game (the job grades that itself) and nothing else.
      assert [request] = engine_requests()
      assert request["turns"] == [List.last(request["turns"])]
      assert hd(request["turns"])["index"] == row.turns - 1
      # At the depth the grades were given at, so the review is all of one.
      assert request["move_level"] == "4ply"

      # The answer is the shape every reader of a stored answer expects,
      # plus a word about where it came from.
      assert row.response["assembled"] == true
      assert length(row.response["turns"]) == row.turns
      assert [_, _] = row.response["players"]
      assert Enum.map(row.response["turns"], & &1["index"]) == Enum.to_list(0..(row.turns - 1))

      # And the grades are spent.
      assert Reviews.turn_grades(game_id, 1, ["anything"]) == [nil]
    end

    test "a game nothing graded is the batch review it always was" do
      test_pid = self()
      engine_echoing(test_pid)
      Application.put_env(:oskol, Grader, enabled: false)

      game_id = finished_game(15)
      [row] = wait_for(fn -> Enum.filter(Reviews.stored(game_id), &(&1.status == "done")) end)

      requests = engine_requests()
      assert [request] = requests
      assert length(request["turns"]) == row.turns
      # The whole game, in order, with nothing added to the body.
      refute Enum.any?(request["turns"], &Map.has_key?(&1, "index"))
      refute Map.has_key?(request, "move_level")
      refute row.response["assembled"]
    end
  end

  # ---------- Helpers ----------

  defp engine_requests do
    receive do
      {:engine, request, _body} -> [request | engine_requests()]
    after
      0 -> []
    end
  end

  # An engine that grades whatever it is asked about, echoing each turn's
  # index, so a lone turn and the same turn in a whole game come back the
  # same -- which is the property the real engine has and the cache needs.
  defp engine_echoing(test_pid) do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
      request = Jason.decode!(body)
      # The raw body too: a grade is keyed on the exact bytes Gleam built,
      # and re-encoding this map would not reproduce them.
      send(test_pid, {:engine, request, body})

      turns =
        request["turns"]
        |> Enum.with_index()
        |> Enum.map(fn {turn, at} -> graded_turn(turn["index"] || at, turn["player"]) end)

      Req.Test.json(conn, %{
        "levels" => %{"move" => "4ply", "cube" => "4ply", "luck" => "3ply"},
        "timing_ms" => 100 * length(turns),
        "turns" => turns,
        "players" => [grader_totals(), grader_totals()]
      })
    end)
  end

  defp graded_turn(index, player) do
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

    %{
      "index" => index,
      "player" => player || 0,
      "cube" => nil,
      "luck" => %{"luck" => 0.1},
      "move" => %{
        "played" => candidate.(2, -0.05),
        "best" => candidate.(1, 0.0),
        "top" => [candidate.(1, 0.0), candidate.(2, -0.05)],
        "results" => for(r <- 1..4, do: %{"board" => [], "equity_diff" => -0.01 * r}),
        "n_legal" => 4,
        "forced" => false,
        "error" => 0.05,
        "grade" => "doubtful"
      }
    }
  end

  defp grader_totals do
    %{
      "moves" => %{
        "decisions" => 1,
        "forced" => 0,
        "error" => 0.05,
        "grades" => %{"doubtful" => 1}
      },
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.1,
      "error" => 0.05,
      "pr" => 25.0
    }
  end

  defp age(game_id, days) do
    from(t in Oskol.Reviews.TurnGrade, where: t.game_id == ^game_id)
    |> Repo.update_all(
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)]
    )
  end
end
