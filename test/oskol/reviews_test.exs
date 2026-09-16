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

  # An engine that grades every turn it is sent as a doubtful move, and
  # counts the requests it gets.
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

    %{
      "turns" =>
        for i <- 0..(n - 1) do
          %{
            "index" => i,
            "cube" => nil,
            "move" => %{
              "played" => candidate.(1, 0.0),
              "best" => candidate.(1, 0.0),
              "top" => [candidate.(1, 0.0)],
              "n_legal" => 4,
              "forced" => false,
              "error" => 0.0,
              "grade" => "best"
            },
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

  defp reviews(conn, game_id) do
    conn
    |> as_guest(seat_guest(game_id))
    |> get("/papi/games/backgammon/rooms/#{game_id}/reviews")
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

    body = reviews(conn, game_id)
    assert body["ok"] == true
    assert [%{"name" => "Alice", "color" => "white"}, %{"name" => "Bob"}] = body["players"]
    assert [%{"game_number" => 1, "status" => "done", "review" => review}] = body["games"]

    assert [%{"pr" => 4.2, "moves" => %{"grades" => %{"ok" => _, "best" => 0}}}, _] =
             review["players"]

    assert [%{"number" => 1, "move" => %{"grade" => "best"}, "luck" => 0.1} | _] =
             review["turns"]

    # Already done: asking again runs nothing
    Queue.enqueue(game_id)
    Queue.await_idle()
    refute_received {:engine, _}
  end

  test "a game finished before reviews existed is queued by the first request", %{conn: conn} do
    # Finished with the queue off, as every game in production today was
    Application.put_env(:oskol, Queue, enabled: false)
    game_id = finished_game(6)
    Persister.flush()
    Application.put_env(:oskol, Queue, enabled: true)
    engine(self())

    assert [%{"status" => "pending", "review" => nil}] = reviews(conn, game_id)["games"]

    wait_for(fn -> Enum.any?(Reviews.stored(game_id), &(&1.status == "done")) end)
    assert [%{"status" => "done"}] = reviews(conn, game_id)["games"]
  end

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

    %{game_id: game_id} = started(2, "match3")
    assert {:finished, _} = Oskol.Bots.play(game_id, 2, 3000)
    assert_receive {:holding, engine}, 10_000
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
