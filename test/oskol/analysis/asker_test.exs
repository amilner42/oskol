defmodule Oskol.Analysis.AskerTest do
  @moduledoc """
  The analysis board's asks through real requests, with the asker on and the
  engine a Req.Test stub (`Oskol.CompleteEngine`). What decides -- the
  cache, the budgets, the refusals, what an answer must hold -- is tested in
  Gleam (test/oskol/analysis_handler_test.gleam). What is here is what only
  the real line can show: one engine call per key however many ask, two at
  once and twenty waiting, the circuit after a failure, the budget counted
  in the real limiter, and the row and picture an answer leaves.
  """
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Analysis.Asker
  alias Oskol.Limiter
  alias Oskol.Puzzles
  alias Oskol.Puzzles.Pictures
  alias Oskol.Repo

  @opening [-2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2]

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Req.Test.set_req_test_to_shared()
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)

    asker = Application.get_env(:oskol, Asker)
    budget = Application.get_env(:oskol, :analysis_budget)
    Application.put_env(:oskol, Asker, Keyword.put(asker, :enabled, true))

    Application.put_env(:oskol, :analysis_budget,
      guest_hour: 100,
      guest_day: 100,
      user_hour: 100,
      user_day: 100,
      global_day: 100
    )

    :ok = Asker.reset()
    :ok = Limiter.reset()

    on_exit(fn ->
      Application.put_env(:oskol, Asker, asker)
      Application.put_env(:oskol, :analysis_budget, budget)
      :ok = Asker.reset()
      :ok = Limiter.reset()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    guest_id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    %{conn: as_guest(build_conn(), guest_id), guest_id: guest_id}
  end

  # ---------- Positions ----------

  defp opening(roll \\ [3, 1]) do
    %{
      "points" => @opening,
      "white_bar" => 0,
      "black_bar" => 0,
      "to_play" => "white",
      "ask" => "move",
      "dice" => roll,
      "cube" => %{"value" => 1, "owner" => "center"},
      "match" => nil
    }
  end

  # The opening at a different match score: as many distinct keys as a
  # test needs, every one of them 3-1 from the start.
  defp scored(white) do
    Map.put(opening(), "match", %{
      "length" => 25,
      "white" => white,
      "black" => 0,
      "crawford" => false
    })
  end

  defp ask(conn, setup), do: post(conn, ~p"/papi/analysis", setup)

  defp status(conn, key), do: get(conn, ~p"/papi/analysis/#{key}")

  # An engine that tells the test it was asked and waits to be let go, so a
  # test can hold asks in flight. `answer` is what it does once let go.
  defp held_engine(answer \\ &Oskol.CompleteEngine.respond/1) do
    test = self()

    Req.Test.stub(Oskol.Reviews, fn conn ->
      send(test, {:engine, self()})

      receive do
        :go -> answer.(conn)
      after
        10_000 -> Plug.Conn.send_resp(conn, 504, "held too long")
      end
    end)
  end

  defp release(count) do
    for _ <- 1..count do
      assert_receive {:engine, pid}, 5_000
      send(pid, :go)
    end
  end

  # ---------- One key, one engine call ----------

  test "two asks of one position make one engine call, and both read done", %{conn: conn} do
    held_engine()

    first = conn |> ask(opening()) |> json_response(202)
    assert %{"ok" => true, "status" => "pending", "key" => key} = first
    assert_receive {:engine, pid}, 5_000

    # The same position again while it is in flight joins it.
    assert %{"status" => "pending", "key" => ^key} = conn |> ask(opening()) |> json_response(202)
    assert %{"ok" => true, "status" => "pending"} = conn |> status(key) |> json_response(200)

    send(pid, :go)
    :ok = Asker.await_idle()
    refute_received {:engine, _}

    for _ <- 1..2 do
      done = conn |> status(key) |> json_response(200)
      assert %{"ok" => true, "status" => "done", "key" => ^key, "puzzle" => puzzle} = done
      assert %{"kind" => "move", "prompt" => "White to play 3-1. What's your play?"} = puzzle
      assert %{"tree" => %{"nodes" => _}, "question" => %{"dice" => [3, 1]}} = puzzle

      assert %{"best" => %{"rank" => 1}, "top" => top, "cube" => nil, "n_legal" => n} =
               done["reveal"]

      assert length(top) == min(5, n)
      assert done["reveal"]["levels"] == %{"moves" => "4ply", "cube" => "4ply"}
    end

    # And now the position is free: answered from the row, 200, nothing asked.
    assert %{"status" => "done", "key" => ^key} = conn |> ask(opening()) |> json_response(200)
    refute_received {:engine, _}
  end

  test "the row is an analysis puzzle with its picture, and TRY ONE never draws it",
       %{conn: conn} do
    %{"key" => key} = conn |> ask(opening([6, 5])) |> json_response(202)
    :ok = Asker.await_idle()
    %{"puzzle" => %{"id" => id}} = conn |> status(key) |> json_response(200)

    assert %{origin: "analysis", complete: true, key: ^key} = Repo.get(Puzzles.Puzzle, id)
    assert Pictures.exists?(id)
    refute Enum.any?(Puzzles.sample(100), &(&1.id == id))
    assert Puzzles.sample_move() == nil
  end

  test "a game's own row keeps its origin when the same position is analyzed",
       %{conn: conn} do
    # Not complete, so the ask goes to the engine; the row and its id stay.
    question = :oskol@practice@openings.question(:oskol@practice@openings.start(), {3, 1})
    key = :oskol@puzzles.key(question)
    [id | _] = :oskol@puzzles.ids(question)

    Repo.insert!(%Puzzles.Puzzle{
      id: id,
      key: key,
      kind: "move",
      question: Jason.decode!(:gleam@json.to_string(:oskol@puzzles.question_json(question))),
      answer: %{"kind" => "move", "outcomes" => [], "complete" => false, "candidates" => []},
      evaluated_by: %{},
      complete: false
    })

    assert %{"key" => ^key} = conn |> ask(opening()) |> json_response(202)
    :ok = Asker.await_idle()

    assert %{origin: "game", complete: true, id: ^id} = Repo.get_by(Puzzles.Puzzle, key: key)
  end

  # ---------- The line ----------

  test "two in flight, the third waits, and past twenty waiting is 429", %{conn: conn} do
    held_engine()

    keys =
      for white <- 0..21 do
        %{"key" => key} = conn |> ask(scored(white)) |> json_response(202)
        key
      end

    # Two asked at once; the third and the rest wait their turn.
    assert_receive {:engine, a}, 5_000
    assert_receive {:engine, b}, 5_000
    refute_receive {:engine, _}, 200

    assert %{"ok" => false, "error" => error} = conn |> ask(scored(22)) |> json_response(429)
    assert %{"code" => "rate_limited", "retry_after_s" => 60} = error
    assert error["message"] == "The engine is busy. Try again in a minute."

    send(a, :go)
    send(b, :go)
    release(20)
    :ok = Asker.await_idle()

    for key <- keys do
      assert %{"status" => "done"} = conn |> status(key) |> json_response(200)
    end
  end

  test "an engine that fails opens the circuit: the waiting fail, the next ask is 503",
       %{conn: conn, guest_id: guest_id} do
    Application.put_env(
      :oskol,
      Asker,
      Keyword.put(Application.get_env(:oskol, Asker), :in_flight, 1)
    )

    held_engine(fn conn -> Plug.Conn.send_resp(conn, 500, "asleep") end)

    %{"key" => first} = conn |> ask(scored(0)) |> json_response(202)
    %{"key" => waiting} = conn |> ask(scored(1)) |> json_response(202)
    release(1)
    :ok = Asker.await_idle()

    message = "The engine is asleep. Try again in a minute."

    for key <- [first, waiting] do
      assert %{"ok" => true, "status" => "failed", "message" => ^message} =
               conn |> status(key) |> json_response(200)
    end

    refute_received {:engine, _}

    assert %{"ok" => false, "error" => error} = conn |> ask(scored(2)) |> json_response(503)
    assert %{"code" => "engine_down", "message" => ^message, "retry_after_s" => s} = error
    assert s in 1..60
    refute_receive {:engine, _}, 100

    # The one asked was charged; the one that waited never reached the
    # engine and was handed back; the 503 was never charged.
    assert [{_, _, 1, _}] = :ets.lookup(Limiter, "analysis:guest:#{guest_id}:hour")
    assert [{_, _, 1, _}] = :ets.lookup(Limiter, "analysis:global:day")
  end

  test "an engine that refuses one position (a 4xx) fails that key alone, and the circuit stays shut",
       %{conn: conn} do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      Plug.Conn.send_resp(conn, 422, ~s({"detail":"played board is not a legal move"}))
    end)

    %{"key" => key} = conn |> ask(scored(0)) |> json_response(202)
    :ok = Asker.await_idle()

    assert %{"status" => "failed", "message" => message} =
             conn |> status(key) |> json_response(200)

    assert message == "The engine could not read this position. Check the board and try another."

    # Nobody else is told the engine is asleep: the next position is asked.
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
    %{"key" => other} = conn |> ask(scored(1)) |> json_response(202)
    :ok = Asker.await_idle()
    assert %{"status" => "done"} = conn |> status(other) |> json_response(200)
  end

  test "a cube question is asked, kept with its chances, and revealed", %{conn: conn} do
    double = opening() |> Map.put("ask", "double") |> Map.put("dice", nil)

    %{"key" => key} = conn |> ask(double) |> json_response(202)
    :ok = Asker.await_idle()

    done = conn |> status(key) |> json_response(200)
    assert %{"status" => "done", "puzzle" => %{"kind" => "double", "tree" => nil}} = done
    assert %{"best" => nil, "top" => [], "n_legal" => nil, "cube" => cube} = done["reveal"]

    assert %{"no_double" => 0.62, "double_take" => 1.31, "double_pass" => 1.0, "probs" => p} =
             cube

    assert p["win"] == 0.52

    assert %{origin: "analysis", complete: true, kind: "double"} =
             Repo.get_by(Puzzles.Puzzle, key: key)

    # A take of the same position, asked of the other side, is its own key.
    take = double |> Map.put("ask", "take") |> Map.put("to_play", "black")
    assert %{"key" => take_key} = conn |> ask(take) |> json_response(202)
    refute take_key == key
    :ok = Asker.await_idle()
  end

  test "an answer the engine sends short of every play is a failure, and nothing is written",
       %{conn: conn} do
    Req.Test.stub(Oskol.Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 20_000_000)
      answer = Oskol.CompleteEngine.answer(Jason.decode!(body))
      [turn] = answer["turns"]
      short = update_in(turn, ["move", "results"], &Enum.drop(&1, 1))
      Req.Test.json(conn, %{answer | "turns" => [short]})
    end)

    %{"key" => key} = conn |> ask(opening()) |> json_response(202)
    :ok = Asker.await_idle()

    assert %{
             "status" => "failed",
             "message" => "The engine could not answer that one. Try again."
           } =
             conn |> status(key) |> json_response(200)

    assert Repo.get_by(Puzzles.Puzzle, key: key) == nil
  end

  # ---------- The budgets ----------

  test "past the budget is 429, and a position already analyzed is still free",
       %{conn: conn} do
    Application.put_env(:oskol, :analysis_budget,
      guest_hour: 1,
      guest_day: 30,
      user_hour: 30,
      user_day: 150,
      global_day: 600
    )

    %{"key" => key} = conn |> ask(opening()) |> json_response(202)
    :ok = Asker.await_idle()

    assert %{"ok" => false, "error" => error} = conn |> ask(opening([6, 4])) |> json_response(429)
    assert %{"code" => "rate_limited", "retry_after_s" => s} = error
    assert s in 1..3_600
    assert error["message"] =~ "Guests can analyze 1 positions an hour."

    assert %{"status" => "done", "key" => ^key} = conn |> ask(opening()) |> json_response(200)
  end

  # ---------- The envelope ----------

  test "a roll that plays nothing, a position that cannot be asked, and an unknown key",
       %{conn: conn} do
    closed =
      Map.merge(opening([6, 4]), %{
        "points" => [
          -3,
          0,
          0,
          0,
          0,
          14,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          -2,
          -2,
          -2,
          -2,
          -2,
          -2
        ],
        "white_bar" => 1
      })

    assert %{"ok" => false, "error" => %{"code" => "dances", "message" => message}} =
             conn |> ask(closed) |> json_response(409)

    assert message == "6-4 cannot be played from here"

    assert %{
             "ok" => false,
             "error" => %{"code" => "validation_failed", "message" => "Pick a roll"}
           } =
             conn |> ask(Map.put(opening(), "dice", nil)) |> json_response(422)

    assert %{"error" => %{"code" => "validation_failed"}} =
             conn |> ask(%{"points" => "nope"}) |> json_response(422)

    assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
             conn |> status(String.duplicate("0", 64)) |> json_response(404)

    refute_received {:engine, _}
    assert Repo.aggregate(from(p in Puzzles.Puzzle), :count) == 0
  end
end
