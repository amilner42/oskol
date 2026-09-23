defmodule Oskol.RatingsTest do
  @moduledoc """
  `/papi/games/:slug/rooms/:id/ratings` end to end: a real room, the
  engine's answers stored against it, and the match PR the table prints.
  What is worth printing is decided in Gleam and tested on stubs
  (test/oskol/ratings_handler_test.gleam).
  """
  use OskolWeb.ConnCase, async: false

  import Oskol.GameFixtures

  alias Oskol.Auth
  alias Oskol.Game.Persister
  alias Oskol.Persistence
  alias Oskol.Repo
  alias Oskol.Reviews

  # A ratings read is a page's poll: it must stay in the same class as the
  # home's whole answer, which the brief budgets at 100 ms.
  @budget_ms 100

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # The engine's answer, cut down to the one field a match PR reads. The
  # players are positional: seat order.
  defp answer(first, second) do
    %{"turns" => [], "players" => [%{"pr" => first}, %{"pr" => second}]}
  end

  defp ratings(conn, game_id) do
    conn
    |> get("/papi/games/backgammon/rooms/#{game_id}/ratings")
    |> json_response(200)
  end

  # A finished room somewhere else on the site with `user_id` in seat 0, and
  # one graded game in it: `error` equity lost over `decisions` decisions,
  # which is what a career is added up from.
  defp elsewhere(user_id, weight), do: elsewhere(user_id, weight, & &1)

  defp elsewhere(user_id, {error, decisions}, shape) do
    game_id = unique_game_id("c")
    owned_room(game_id, user_id)

    :ok =
      Reviews.save(game_id, 1, "done", 1, shape.(totals_answer(error, decisions)), nil, nil, 30)

    game_id
  end

  defp owned_room(game_id, user_id) do
    Repo.insert!(%Persistence.Game{
      id: game_id,
      slug: "backgammon",
      config: %{"format" => "single", "clock" => "none"},
      seed: 42,
      players: [
        %{"id" => "p1", "name" => "Alice", "guest_id" => unique_guest_id(), "user_id" => user_id},
        %{"id" => "p2", "name" => "Bob", "guest_id" => unique_guest_id(), "user_id" => nil}
      ],
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    :ok
  end

  # The engine's answer with the totals a career is made of, at whatever
  # weight the caller wants.
  defp totals_answer(error, decisions) do
    seat = fn error, decisions ->
      %{
        "moves" => %{"decisions" => decisions, "forced" => 0, "error" => error, "grades" => %{}},
        "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
        "luck" => 0.0,
        "error" => error,
        "pr" => error / decisions * 500
      }
    end

    %{"turns" => [], "players" => [seat.(error, decisions), seat.(1.0, 10)]}
  end

  defp seat(players, id), do: Enum.find(players, &(&1["player_id"] == id))

  test "unanswered ratings rows keep a null body and answered false" do
    %{game_id: game_id} = started(42, "match5")
    Persister.flush()
    :ok = Reviews.save(game_id, 1, "pending", 1, nil, nil, nil, 1)

    assert [%{response: nil}] = Reviews.rating_summaries(game_id)

    {:analysis_caps, _, _, ratings, _, _, _, _, _, _, _, _, _, _} =
      Oskol.Gleam.Caps.Analysis.build()

    assert [{:stored, 1, :pending, 1, :none, false, false, 1}] = ratings.(game_id)
  end

  test "a match averages the games its own engine answers graded", %{conn: conn} do
    %{game_id: game_id, p1: p1, p2: p2} = started(42, "match5")
    Persister.flush()

    # Nothing graded yet: both seats are named, neither wears a number, and
    # nothing is owed, so a watching table is told to stop asking.
    assert %{"ok" => true, "pending" => false, "players" => none} = ratings(conn, game_id)
    assert %{"games" => 0, "pr" => nil} = seat(none, p1)
    assert %{"games" => 0, "pr" => nil} = seat(none, p2)

    # One graded game shows its own PR.
    :ok = Reviews.save(game_id, 1, "done", 1, answer(8.0, 12.0), nil, nil, 1)
    assert %{"players" => one} = ratings(conn, game_id)
    assert %{"games" => 1, "pr" => 8.0} = seat(one, p1)
    assert %{"games" => 1, "pr" => 12.0} = seat(one, p2)

    # A second lands: the plain mean of the two, to one decimal.
    :ok = Reviews.save(game_id, 2, "done", 1, answer(9.0, 13.0), nil, nil, 1)
    assert %{"players" => two} = ratings(conn, game_id)
    assert %{"games" => 2, "pr" => 8.5} = seat(two, p1)
    assert %{"games" => 2, "pr" => 12.5} = seat(two, p2)

    # A game still pending and one the engine gave up on count for nothing.
    :ok = Reviews.save(game_id, 3, "pending", 0, nil, nil, nil, 1)
    :ok = Reviews.save(game_id, 4, "failed", 3, nil, "the engine said no", nil, 1)
    assert %{"pending" => true, "players" => still_two} = ratings(conn, game_id)
    assert %{"games" => 2, "pr" => 8.5} = seat(still_two, p1)

    # The engine answers the one it was working on: nothing owed again.
    :ok = Reviews.save(game_id, 3, "done", 1, answer(7.0, 11.0), nil, nil, 1)
    assert %{"pending" => false, "players" => three} = ratings(conn, game_id)
    assert %{"games" => 3, "pr" => 8.0} = seat(three, p1)
  end

  test "a room that is not there says so, and says nothing else", %{conn: conn} do
    assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
             conn
             |> get("/papi/games/backgammon/rooms/nobody/ratings")
             |> json_response(404)
  end

  test "cold ratings leave the room stopped and transfer no turn analysis", %{conn: conn} do
    %{game_id: game_id} = started(42, "match5")
    Persister.flush()
    large = %{"large" => String.duplicate("x", 100_000)}

    response =
      Map.put(answer(8.0, 12.0), "turns", [
        %{"player" => 0, "cube" => nil, "move" => large},
        large
      ])

    :ok = Reviews.save(game_id, 1, "done", 1, response, nil, %{"large" => "report"}, 1)

    {:ok, pid} = Oskol.Game.GameSupervisor.find_game(game_id)
    ref = Process.monitor(pid)
    :ok = DynamicSupervisor.terminate_child(Oskol.Game.GameSupervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    wait_for_stopped_room(game_id)

    [row] = Reviews.rating_summaries(game_id)
    # The seats' totals and the first turn's seat and cube verdict (none
    # here), never a move's analysis or a later turn
    assert row.response == %{"players" => response["players"], "turns" => [%{"player" => 0}]}
    assert %{"players" => [%{"pr" => 8.0}, %{"pr" => 12.0}]} = ratings(conn, game_id)
    assert Oskol.Game.GameSupervisor.find_game(game_id) == :error
  end

  test "the opening roll's no double counts for nothing in a match PR", %{conn: conn} do
    %{game_id: game_id} = started(43, "match5")
    Persister.flush()
    # How the engine totals it: seat 1 opened behind after Crawford and was
    # charged a 0.07 missed double on the opening roll, over 3 checker plays
    totals = fn cube_decisions, cube_error, pr ->
      %{
        "moves" => %{"decisions" => 3, "forced" => 0, "error" => 0, "grades" => %{}},
        "cube" => %{"decisions" => cube_decisions, "error" => cube_error, "mistakes" => %{}},
        "luck" => 0,
        "error" => cube_error,
        "pr" => pr
      }
    end

    opening = %{
      "index" => 0,
      "player" => 1,
      "cube" => %{
        "action" => "no_double",
        "response" => nil,
        "analysis" => %{
          "optimal_action" => "Double/Pass",
          "equity_nd" => 0.9,
          "equity_dt" => 1.2,
          "equity_dp" => 1.0
        },
        "doubler" => %{"error" => 0.07, "grade" => "doubtful", "mistake" => "missed_double"},
        "taker" => nil
      }
    }

    response = %{"turns" => [opening], "players" => [totals.(0, 0, 0.0), totals.(1, 0.07, 8.75)]}
    :ok = Reviews.save(game_id, 1, "done", 1, response, nil, %{"large" => "report"}, 1)

    assert %{"players" => [%{"pr" => +0.0}, %{"pr" => +0.0}]} = ratings(conn, game_id)
  end

  describe "the career beside the match PR" do
    test "an owned seat wears its account's career, and an unowned seat none", %{conn: conn} do
      user = Auth.find_or_create_user("career@oskol.test")
      %{game_id: game_id, p1: p1, p2: p2} = started(42, "match5", user: user.id)
      Persister.flush()

      # Four graded games is not a career yet: the floor is five.
      for _ <- 1..4, do: elsewhere(user.id, {0.2, 10})
      assert %{"players" => four} = ratings(conn, game_id)
      assert %{"pr" => nil, "career" => nil} = seat(four, p1)

      # The fifth makes one: 1.0 of equity lost over 50 decisions, times
      # 500, is a PR of 10.0. The seat opposite belongs to no account and
      # stays bare, which is what a guest sees for ever.
      elsewhere(user.id, {0.2, 10})
      assert %{"players" => five} = ratings(conn, game_id)
      assert %{"career" => 10.0} = seat(five, p1)
      assert %{"career" => nil} = seat(five, p2)

      # A sixth game, three decisions long and played badly (its own PR is
      # 166.7). Averaging the six PRs would give 36.1 and let that one game
      # speak for the whole career; the equity lost over the decisions it
      # was lost over gives 2.0 over 53, which is 18.9.
      elsewhere(user.id, {1.0, 3})
      assert %{"players" => six} = ratings(conn, game_id)
      assert %{"career" => 18.9} = seat(six, p1)

      # The match PR is still this room's own games, and still empty.
      assert %{"games" => 0, "pr" => nil} = seat(six, p1)
    end

    test "this room's own graded games are part of the career too", %{conn: conn} do
      user = Auth.find_or_create_user("here@oskol.test")
      %{game_id: game_id, p1: p1} = started(42, "match5", user: user.id)
      Persister.flush()

      for _ <- 1..4, do: elsewhere(user.id, {0.2, 10})
      :ok = Reviews.save(game_id, 1, "done", 1, totals_answer(0.2, 10), nil, nil, 30)

      # Five graded games, one of them the one on the board: the career is
      # the same 10.0, and the match PR is that one game's own rating.
      assert %{"players" => players} = ratings(conn, game_id)
      assert %{"games" => 1, "pr" => 10.0, "career" => 10.0} = seat(players, p1)
    end

    test "a review whose stored answer carries no totals counts for nothing", %{conn: conn} do
      user = Auth.find_or_create_user("totalless@oskol.test")
      %{game_id: game_id, p1: p1} = started(42, "match5", user: user.id)
      Persister.flush()

      for _ <- 1..4, do: elsewhere(user.id, {0.2, 10})

      # A row as they were written before totals were stored: a rating and
      # nothing to add up. It is not a fifth game, and it is not a zero.
      _ =
        elsewhere(user.id, {0.2, 10}, fn _ ->
          %{"turns" => [], "players" => [%{"pr" => 4.0}, %{"pr" => 9.0}]}
        end)

      assert %{"players" => players} = ratings(conn, game_id)
      assert %{"career" => nil} = seat(players, p1)
    end

    @tag :slow
    test "two owned seats with a hundred games each answer inside the budget", %{conn: conn} do
      alice = Auth.find_or_create_user("alice-cost@oskol.test")
      bob = Auth.find_or_create_user("bob-cost@oskol.test")

      %{game_id: game_id, p1: p1, p2: p2} = started(42, "match5", user: alice.id)
      Persister.flush()

      # Bob's seat, stamped as a sign-in would stamp it.
      row = Repo.get!(Persistence.Game, game_id)

      players =
        Enum.map(row.players, fn p ->
          if p["id"] == p2, do: Map.put(p, "user_id", bob.id), else: p
        end)

      Repo.update!(Ecto.Changeset.change(row, players: players))

      for _ <- 1..100 do
        elsewhere(alice.id, {3.0, 30})
        elsewhere(bob.id, {6.0, 30})
      end

      # Warm the connection and the plan, then measure the request itself.
      _ = ratings(conn, game_id)
      {us, body} = :timer.tc(fn -> ratings(recycle(conn), game_id) end)
      ms = us / 1000

      assert %{"career" => 50.0} = seat(body["players"], p1)
      assert %{"career" => 100.0} = seat(body["players"], p2)

      IO.puts(
        "\n  GET .../ratings, two owned seats, 100 graded games each: #{Float.round(ms, 1)} ms"
      )

      assert ms < @budget_ms,
             "ratings took #{Float.round(ms, 1)} ms with two careers of 100 games (budget #{@budget_ms} ms)"
    end
  end

  defp wait_for_stopped_room(game_id, tries \\ 100)

  defp wait_for_stopped_room(game_id, 0),
    do: assert(Oskol.Game.GameSupervisor.find_game(game_id) == :error)

  defp wait_for_stopped_room(game_id, tries) do
    if Oskol.Game.GameSupervisor.find_game(game_id) != :error do
      Process.sleep(10)
      wait_for_stopped_room(game_id, tries - 1)
    end
  end

  test "a room still in its lobby answers the same 404", %{conn: conn} do
    %{game_id: game_id} = lobby()

    assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
             conn
             |> get("/papi/games/backgammon/rooms/#{game_id}/ratings")
             |> json_response(404)
  end
end
