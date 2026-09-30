defmodule OskolWeb.StatusTest do
  @moduledoc """
  `GET /status` says whether the analysis engine answered, along the road a
  review takes, and shows a position it just analysed. It is the only thing
  in the product that reports on a machine we do not control the power to,
  so what it must never do is read green while the engine is unreachable —
  or while something that is not the engine is answering for it.

  The engine here is a `Req.Test` stub, as everywhere else — no network.
  The board is looked at in a task in production; these tests take the look
  themselves (`StatusController.refresh/0`) rather than race one.
  """
  use OskolWeb.ConnCase, async: false

  alias Oskol.Puzzles
  alias Oskol.Repo
  alias OskolWeb.StatusController

  setup do
    # Shared, and so `async: false`: the board is looked at in a task in
    # production, and a test that takes the look itself still runs it from
    # a process that is not this one.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Oskol.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    Req.Test.set_req_test_to_shared()
    # The caches are process-independent, so a stub swapped between tests is
    # not seen until they expire. Clear them instead of sleeping.
    clear = fn ->
      :persistent_term.erase({StatusController, :last})
      :persistent_term.erase({StatusController, :board})
    end

    on_exit(clear)
    clear.()
    :ok
  end

  # One stub for both roads: `/health` asks whether it is there and
  # `/backgammon/review` asks it to think. A stub that answered only the
  # first is exactly the failure this page exists to catch.
  defp engine(opts) do
    health = Keyword.get(opts, :health, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

    review =
      Keyword.get(opts, :review, fn conn -> Plug.Conn.send_resp(conn, 200, an_answer()) end)

    Req.Test.stub(Oskol.Reviews, fn conn ->
      case conn.request_path do
        "/health" -> health.(conn)
        "/backgammon/review" -> review.(conn)
      end
    end)
  end

  defp an_answer(notation \\ "13/7 8/7") do
    Jason.encode!(%{
      "levels" => %{"moves" => "4ply", "cube" => "4ply"},
      "timing_ms" => 2571,
      "turns" => [
        %{
          "index" => 1,
          "player" => 0,
          "move" => %{
            "best" => a_play(notation, 0.152, 0.0, 0.584),
            "top" => [
              a_play(notation, 0.152, 0.0, 0.584),
              a_play("24/18 13/10", -0.021, -0.173, 0.551)
            ]
          }
        }
      ]
    })
  end

  defp a_play(notation, equity, diff, win) do
    %{
      "rank" => 1,
      "notation" => notation,
      "equity" => equity,
      "equity_diff" => diff,
      "probs" => %{
        "win" => win,
        "gammon_win" => 0.1,
        "backgammon_win" => 0.0,
        "gammon_loss" => 0.1,
        "backgammon_loss" => 0.0
      }
    }
  end

  # A stored puzzle, exactly as extraction would have written it, under an
  # id no other test uses: the table is global.
  defp a_puzzle do
    {:stored, _id, kind, question, answer} = :oskol@puzzles@fixture.stored_sample("move")
    id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    Repo.insert!(%Puzzles.Puzzle{
      id: id,
      key: "status-" <> id,
      kind: kind,
      complete: true,
      question: Jason.decode!(question),
      answer: Jason.decode!(answer),
      evaluated_by: %{}
    })

    id
  end

  # ---------- Is it there? ----------

  test "an engine that answers reads UP, and 200", %{conn: conn} do
    engine([])
    settle()

    conn = get(conn, ~p"/status")
    body = response(conn, 200)

    assert body =~ "UP"
    refute body =~ "DOWN"
    assert body =~ "answered in"
  end

  test "an engine that refuses reads DOWN, and 503 so a machine can watch it", %{conn: conn} do
    engine(health: fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    settle()

    conn = get(conn, ~p"/status")
    body = response(conn, 503)

    assert body =~ "DOWN"
    refute body =~ ">UP<"
  end

  test "an engine that answers badly is down, not up", %{conn: conn} do
    engine(health: fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)
    settle()

    assert get(conn, ~p"/status") |> response(503) =~ "DOWN"
  end

  test "the reason is escaped rather than written into the page", %{conn: conn} do
    engine(health: fn conn -> Plug.Conn.send_resp(conn, 418, "<script>alert(1)</script>") end)
    settle()

    body = get(conn, ~p"/status") |> response(503)
    refute body =~ "<script>alert(1)</script>"
  end

  test "a second hit is served from the cache, so the page cannot be used to make requests",
       %{conn: conn} do
    test_pid = self()
    a_puzzle()

    engine(
      health: fn conn ->
        send(test_pid, :asked)
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    )

    StatusController.refresh()

    assert get(conn, ~p"/status") |> response(200) =~ "UP"
    assert_received :asked

    assert get(build_conn(), ~p"/status") |> response(200) =~ "UP"
    refute_received :asked
  end

  test "it is not indexed: the page is for whoever runs the machine", %{conn: conn} do
    engine([])
    settle()
    assert get(conn, ~p"/status") |> response(200) =~ ~s(name="robots" content="noindex")
  end

  # ---------- Is it the engine? ----------

  test "the board is the position drawn and the engine's own plays under it", %{conn: conn} do
    a_puzzle()
    engine([])

    StatusController.refresh()
    body = get(conn, ~p"/status") |> response(200)

    assert body =~ "<svg"
    assert body =~ "13/7 8/7"
    assert body =~ "24/18 13/10"
    # Signed, best first, with the chances beside them.
    assert body =~ "+0.152"
    assert body =~ "-0.021"
    assert body =~ "58.4%"
    # And what the engine said about itself.
    assert body =~ "4ply"
    assert body =~ "2.6s"
  end

  test "a stub that answers everything with ok cannot pass: that is the point of the board",
       %{conn: conn} do
    # The failure this page was rebuilt for. `/health` is a line of Python
    # and a twelve-line stub answers it; naming the best play of a board it
    # has never seen is not something a stub does.
    a_puzzle()
    engine(review: fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"ok":true})) end)

    StatusController.refresh()
    body = get(conn, ~p"/status") |> response(503)

    assert body =~ "did not analyse"
    assert body =~ "DOWN"
    refute body =~ ">UP<"
  end

  test "an engine that is there but will not analyse is down", %{conn: conn} do
    a_puzzle()
    engine(review: fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    StatusController.refresh()
    body = get(conn, ~p"/status") |> response(503)

    assert body =~ "did not analyse"
  end

  test "an engine that names no play is not analysing either", %{conn: conn} do
    a_puzzle()

    answer = Jason.encode!(%{"turns" => [%{"index" => 1, "player" => 0}]})
    engine(review: fn conn -> Plug.Conn.send_resp(conn, 200, answer) end)

    StatusController.refresh()
    assert get(conn, ~p"/status") |> response(503) =~ "did not analyse"
  end

  test "having nothing to draw is not the engine being down", %{conn: conn} do
    # A site whose games have not been graded yet has no position to show.
    # That is not an answer about the engine, and must not read as one.
    engine([])

    StatusController.refresh()
    body = get(conn, ~p"/status") |> response(200)

    assert body =~ "UP"
    assert body =~ "no stored position"
    refute body =~ "did not analyse"
  end

  test "the engine's words are escaped rather than written into the page", %{conn: conn} do
    a_puzzle()
    answer = an_answer("<script>alert(1)</script>")
    engine(review: fn conn -> Plug.Conn.send_resp(conn, 200, answer) end)

    StatusController.refresh()
    body = get(conn, ~p"/status") |> response(200)

    refute body =~ "<script>alert(1)</script>"
    assert body =~ "&lt;script&gt;"
  end

  test "the page renders before the engine has been asked about a position", %{conn: conn} do
    # Nothing here waits on the engine: a page that blocked on it would stop
    # rendering exactly when the engine is the thing that has gone wrong.
    a_puzzle()
    engine([])

    body = get(conn, ~p"/status") |> response(200)

    assert body =~ "UP"
    assert body =~ "asking the engine"
    refute body =~ "<svg"

    # That request started the look. Wait for it here rather than leaving a
    # task to finish after the test's database connection has gone, and take
    # the chance to assert the next reader gets the board.
    wait_for_look()
    assert get(build_conn(), ~p"/status") |> response(200) =~ "<svg"
  end

  # A board this request will not call stale, so nothing is looked at behind
  # it: what a test asking only about health wants. With no puzzle stored
  # this touches the engine not at all.
  defp settle, do: StatusController.refresh()

  # The look runs in a task, so a test that starts one waits for it.
  defp wait_for_look(tries \\ 200) do
    cond do
      :persistent_term.get({StatusController, :board}, nil) != nil -> :ok
      tries == 0 -> flunk("the background look never landed")
      true -> Process.sleep(10) && wait_for_look(tries - 1)
    end
  end
end
