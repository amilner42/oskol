defmodule OskolWeb.Api.HomeApiTest do
  @moduledoc """
  The signed-in home against real rows: the seat-to-account join behind it,
  what it leaves out, how it pages, and what it costs.

  What the page *decides* -- the windows, the weighting, the sentence, the
  three-game floor -- is tested in Gleam on stubs
  (test/oskol/home_handler_test.gleam). What is here is what only the
  database can show: that the join finds an account's seat whichever seat
  it is, that a game the engine has not answered for is not in the answer,
  that the containment test the query is written on is one the index can
  serve, and that a hundred graded games still answer inside the budget.
  """
  # Guest rows are written from the request process: shared sandbox.
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Persistence
  alias Oskol.Repo
  alias Oskol.Reviews

  # The budget the brief sets for the whole answer, on prod's rows.
  @budget_ms 100

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp a_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # A browser signed into this account, as the sign-in leaves it.
  defp signed_in(conn, email) do
    guest_id = a_guest_id()
    user = Auth.find_or_create_user(email)
    conn = conn |> as_guest(guest_id) |> get(~p"/")
    :ok = Auth.bind_guest(guest_id, user.id)
    {recycle(conn), user}
  end

  # One room, with this account in `seat` (0 or 1) and a stranger opposite.
  defp room(game_id, user_id, seat, opts \\ []) do
    mine = %{
      "id" => "p#{seat + 1}",
      "name" => "Typed at the door",
      "guest_id" => a_guest_id(),
      "user_id" => user_id
    }

    theirs = %{
      "id" => "p#{2 - seat}",
      "name" => Keyword.get(opts, :opponent, "Bob"),
      "guest_id" => a_guest_id(),
      "user_id" => Keyword.get(opts, :opponent_user)
    }

    players = if seat == 0, do: [mine, theirs], else: [theirs, mine]

    Repo.insert!(%Persistence.Game{
      id: game_id,
      slug: "backgammon",
      config: %{"format" => "single", "clock" => "none"},
      seed: 42,
      players: players,
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    :ok
  end

  # The engine's answer for one game, at whatever weight the caller wants.
  # `error` and `decisions` are what a rating over several games is made of.
  defp answer(mine, theirs, opts \\ []) do
    %{
      "players" => [totals(mine), totals(theirs)],
      "turns" => Keyword.get(opts, :turns, [])
    }
  end

  defp totals({error, decisions}) do
    %{
      "moves" => %{
        "decisions" => decisions,
        "forced" => 0,
        "error" => error,
        "grades" => %{}
      },
      "cube" => %{"decisions" => 0, "error" => 0.0, "mistakes" => %{}},
      "luck" => 0.0,
      "error" => error,
      "pr" => error / decisions * 500
    }
  end

  defp graded(game_id, number, response) do
    :ok = Reviews.save(game_id, number, "done", 1, response, nil, nil, 30)
  end

  defp recorded(game_id, number, winner) do
    :ok =
      Reviews.save_records(
        game_id,
        [
          {number,
           [
             %{"kind" => "turn", "player" => winner},
             %{
               "kind" => "game_over",
               "number" => number,
               "winner" => winner,
               "result" => "gammon",
               "points" => 2,
               "cube" => 1,
               "scores" => %{}
             }
           ]}
        ],
        1,
        1
      )
  end

  defp home(conn), do: conn |> get(~p"/papi/me/home") |> json_response(200)

  describe "who the home is for" do
    test "a guest is told there is none for them, and nothing else", %{conn: conn} do
      assert %{"ok" => true, "signed_in" => false} = body = home(conn)
      refute Map.has_key?(body, "form")
      refute Map.has_key?(body, "recent")
    end
  end

  describe "the seat-to-account join" do
    test "finds an account's games from either seat, and leaves out what is not graded",
         %{conn: conn} do
      {conn, user} = signed_in(conn, "join@oskol.test")

      # Three rooms: two with this account in seat 0, one in seat 1.
      :ok = room("jaaaaa", user.id, 0)
      :ok = room("jbbbbb", user.id, 0)
      :ok = room("jccccc", user.id, 1, opponent: "Carol")
      :ok = room("jddddd", user.id, 0, opponent: "Dave")

      # The account's own error is 3.0 over 30 decisions in each of the two
      # it is graded for; the opponent's is much worse, so a seat read from
      # the wrong side would show a very different number.
      graded("jaaaaa", 1, answer({3.0, 30}, {30.0, 30}))
      recorded("jaaaaa", 1, "p1")
      # Seat 1: the account's totals are the second entry.
      graded("jccccc", 1, answer({30.0, 30}, {3.0, 30}))
      recorded("jccccc", 1, "p1")
      graded("jddddd", 1, answer({3.0, 30}, {30.0, 30}))
      recorded("jddddd", 1, "p1")
      # Not answered for: it counts for nothing anywhere.
      :ok = Reviews.save("jbbbbb", 1, "pending", 1, nil, nil, nil, 30)

      body = home(conn)

      assert body["signed_in"] == true
      assert body["form"]["games"] == 3
      assert length(body["recent"]) == 3

      assert Enum.map(body["recent"], & &1["game_id"]) |> Enum.sort() ==
               ["jaaaaa", "jccccc", "jddddd"]

      # 9.0 of error over 90 decisions, times 500: the account's own seat
      # every time, not the opponent's (which would read 500.0).
      assert body["form"]["career"] == 50.0

      # The opponent is named from the other seat of each room.
      assert Enum.map(body["recent"], & &1["opponent"]) |> Enum.sort() ==
               ["Bob", "Carol", "Dave"]
    end

    test "the result is read from this account's side", %{conn: conn} do
      {conn, user} = signed_in(conn, "result@oskol.test")
      :ok = room("raaaaa", user.id, 0)
      :ok = room("rbbbbb", user.id, 1)
      graded("raaaaa", 1, answer({3.0, 30}, {6.0, 30}))
      graded("rbbbbb", 1, answer({6.0, 30}, {3.0, 30}))
      # p1 won both. The account is p1 in the first room and p2 in the
      # second, so it won one and lost one.
      recorded("raaaaa", 1, "p1")
      recorded("rbbbbb", 1, "p1")

      results =
        home(conn)["recent"]
        |> Map.new(&{&1["game_id"], &1["result"]})

      assert results["raaaaa"] == %{"won" => true, "points" => 2, "kind" => "gammon"}
      assert results["rbbbbb"] == %{"won" => false, "points" => 2, "kind" => "gammon"}
    end

    test "an account's seat in somebody else's room is not somebody else's game", %{conn: conn} do
      {conn, mine} = signed_in(conn, "mine@oskol.test")
      theirs = Auth.find_or_create_user("theirs@oskol.test")

      :ok = room("maaaaa", mine.id, 0, opponent_user: theirs.id)
      graded("maaaaa", 1, answer({3.0, 30}, {30.0, 30}))
      recorded("maaaaa", 1, "p1")

      # The room is one game for each of them, read from their own seat.
      assert home(conn)["form"]["games"] == 1

      {other_conn, _} = signed_in(build_conn(), "theirs@oskol.test")
      other = home(other_conn)
      assert other["form"]["games"] == 1
      assert hd(other["recent"])["pr"] == 500.0
      # An account with no username yet is named by whatever its seat was
      # taken under, as every other page names it.
      assert hd(other["recent"])["opponent"] == "Typed at the door"

      # Once it has one, that is what everyone sees -- the seat's own name
      # is never what is shown for an owned seat.
      :ok = Auth.claim_name(mine.id, "arie1")
      assert hd(home(recycle(other_conn))["recent"])["opponent"] == "arie1"
    end

    test "reading a home opens no deck and queues no review", %{conn: conn} do
      {conn, user} = signed_in(conn, "reader@oskol.test")
      :ok = room("caaaaa", user.id, 0)
      graded("caaaaa", 1, answer({3.0, 30}, {6.0, 30}))

      body = home(conn)

      assert body["practice"] == %{
               "due" => 0,
               "deck" => 0,
               "ladder" => List.duplicate(0, 8),
               "days" => List.duplicate(false, 30)
             }

      # A read must not make a deck for an account that has never
      # practised, and must not owe the engine anything.
      assert Repo.aggregate(Retain.User, :count) == 0
      assert Repo.aggregate(from(g in Persistence.Game, where: g.analysis_owed), :count) == 0
    end

    test "a graded game with no record row shows no result rather than a guess", %{conn: conn} do
      {conn, user} = signed_in(conn, "norecord@oskol.test")
      :ok = room("naaaaa", user.id, 0)
      graded("naaaaa", 1, answer({3.0, 30}, {6.0, 30}))

      assert hd(home(conn)["recent"])["result"] == nil
    end
  end

  describe "paging" do
    setup %{conn: conn} do
      {conn, user} = signed_in(conn, "paging@oskol.test")
      :ok = room("paaaaa", user.id, 0)

      # One room, twenty-five graded games of a long match.
      for number <- 1..25 do
        graded("paaaaa", number, answer({3.0, 30}, {6.0, 30}))
        recorded("paaaaa", number, "p1")
      end

      {:ok, conn: conn, user: user}
    end

    test "the home carries ten and the next page carries on from it", %{conn: conn} do
      first = home(conn)
      assert length(first["recent"]) == 10
      assert first["more"] == true
      assert first["form"]["games"] == 25

      second =
        conn
        |> recycle()
        |> get(~p"/papi/me/games/graded?before=#{first["next"]}")
        |> json_response(200)

      assert length(second["games"]) == 10
      assert second["more"] == true

      seen = Enum.map(first["recent"] ++ second["games"], & &1["game_number"])
      assert length(Enum.uniq(seen)) == 20

      third =
        conn
        |> recycle()
        |> get(~p"/papi/me/games/graded?before=#{second["next"]}")
        |> json_response(200)

      assert length(third["games"]) == 5
      assert third["more"] == false
      assert third["next"] == nil
    end

    test "a marker that is not one is refused", %{conn: conn} do
      assert %{"ok" => false, "error" => %{"code" => "validation_failed"}} =
               conn
               |> get(~p"/papi/me/games/graded?before=nonsense")
               |> json_response(422)
    end
  end

  describe "the query itself" do
    test "the containment test is one the players index can serve" do
      user = Auth.find_or_create_user("explain@oskol.test")

      # Something to plan over: a handful of this account's rooms among
      # other people's.
      for i <- 1..20 do
        :ok = room("eown#{i}", user.id, 0)
        graded("eown#{i}", 1, answer({3.0, 30}, {6.0, 30}))
      end

      for i <- 1..100, do: :ok = room("eoth#{i}", Ecto.UUID.generate(), 0)

      Repo.query!("ANALYZE games")
      Repo.query!("ANALYZE game_reviews")

      {sql, params} = Reviews.graded_for_sql(user.id, 10)

      # A test database is small enough that PostgreSQL would rightly
      # reach for a sequential scan or the primary key whatever the query
      # said. Taking those away leaves the bitmap paths, and the only
      # index that can answer this predicate is the players GIN -- which
      # is what silently stops being true if the expression ever drifts
      # from the one `games_players_gin` is built on.
      Repo.query!("SET LOCAL enable_seqscan = off")
      Repo.query!("SET LOCAL enable_indexscan = off")
      %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
      plan = rows |> List.flatten() |> Enum.join("\n")

      assert plan =~ "games_players_gin",
             "the seat join no longer uses the players index:\n" <> plan
    end
  end

  describe "what it costs" do
    @tag :slow
    test "a hundred graded games answer inside the budget", %{conn: conn} do
      {conn, user} = signed_in(conn, "budget@oskol.test")
      :ok = room("baaaaa", user.id, 0)

      # Engine answers the size production stores: a turn-by-turn analysis
      # with its candidate moves, so the cost of reaching past one into the
      # totals is the real one.
      turns = bulky_turns()

      for number <- 1..100 do
        graded("baaaaa", number, answer({3.0, 30}, {6.0, 30}, turns: turns))
        recorded("baaaaa", number, "p1")
      end

      # Warm the connection and the plan, then measure the request itself.
      _ = home(conn)

      {us, body} = :timer.tc(fn -> home(recycle(conn)) end)
      ms = us / 1000

      assert body["form"]["games"] == 100
      assert length(body["recent"]) == 10

      IO.puts("\n  GET /papi/me/home with 100 graded games: #{Float.round(ms, 1)} ms")

      assert ms < @budget_ms,
             "the home took #{Float.round(ms, 1)} ms with 100 graded games (budget #{@budget_ms} ms)"
    end
  end

  # About 300 KB of turns, which is what a graded game weighs in production.
  defp bulky_turns do
    candidates =
      for rank <- 1..20 do
        %{
          "rank" => rank,
          "move" => "24/23 13/11",
          "equity" => 0.123_456,
          "equity_diff" => -0.01 * rank,
          "board" => Enum.to_list(1..26),
          "probs" => %{
            "win" => 0.5,
            "gammon_win" => 0.1,
            "backgammon_win" => 0.01,
            "gammon_loss" => 0.1,
            "backgammon_loss" => 0.01
          }
        }
      end

    for number <- 1..60 do
      %{
        "number" => number,
        "player" => rem(number, 2),
        "dice" => [3, 1],
        "board" => Enum.to_list(1..26),
        "candidates" => candidates
      }
    end
  end
end
