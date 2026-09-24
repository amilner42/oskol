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
  # `format` and `status` are what the recent list reads to say what was
  # being played and whether it is over.
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
      config: %{"format" => Keyword.get(opts, :format, "single"), "clock" => "none"},
      seed: 42,
      players: players,
      status: Keyword.get(opts, :status, "finished"),
      winners: Keyword.get(opts, :winners, []),
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

  defp recorded(game_id, number, winner, opts \\ []) do
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
               "result" => Keyword.get(opts, :result, "gammon"),
               "points" => Keyword.get(opts, :points, 2),
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

      assert Enum.map(body["recent"], & &1["id"]) |> Enum.sort() ==
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
      :ok = room("raaaaa", user.id, 0, winners: ["p1"])
      :ok = room("rbbbbb", user.id, 1, winners: ["p1"])
      graded("raaaaa", 1, answer({3.0, 30}, {6.0, 30}))
      graded("rbbbbb", 1, answer({6.0, 30}, {3.0, 30}))
      # p1 won both. The account is p1 in the first room and p2 in the
      # second, so it won one and lost one.
      recorded("raaaaa", 1, "p1")
      recorded("rbbbbb", 1, "p1")

      rooms = Map.new(home(conn)["recent"], &{&1["id"], &1})

      # The room says who won, from its own row...
      assert rooms["raaaaa"]["won"] == true
      assert rooms["rbbbbb"]["won"] == false

      # ...and the game inside it says how, from this account's side.
      assert hd(rooms["raaaaa"]["games"])["result"] ==
               %{"won" => true, "points" => 2, "kind" => "gammon"}

      assert hd(rooms["rbbbbb"]["games"])["result"] ==
               %{"won" => false, "points" => 2, "kind" => "gammon"}

      # The score is that game's points, on the right side of the line.
      assert rooms["raaaaa"]["score"] == %{"yours" => 2, "theirs" => 0}
      assert rooms["rbbbbb"]["score"] == %{"yours" => 0, "theirs" => 2}
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
               "days" => List.duplicate(false, 30),
               # The day's ring: nothing answered and nothing to answer,
               # and no deck opened to find that out.
               "today" => %{"done" => 0, "target" => 0},
               # Three bands, every one of them empty.
               "severity" => [
                 %{"grade" => "very_bad", "total" => 0, "patched" => 0},
                 %{"grade" => "bad", "total" => 0, "patched" => 0},
                 %{"grade" => "doubtful", "total" => 0, "patched" => 0}
               ],
               "patched_level" => 4
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

      assert hd(hd(home(conn)["recent"])["games"])["result"] == nil
      # Nothing was added to either side of a score from a game that says
      # nothing about who won it.
      assert hd(home(conn)["recent"])["score"] == %{"yours" => 0, "theirs" => 0}
    end
  end

  describe "a match" do
    test "nine games of a match to seven are one entry with its score inside", %{conn: conn} do
      {conn, user} = signed_in(conn, "match@oskol.test")
      :ok = room("mmmmmm", user.id, 0, format: "match7", winners: ["p1"])

      # Four lost by a point, five won for seven: the match reads 7-4. The
      # last game is a long one, so the match rating is not the mean of the
      # games' ratings.
      for {number, won, points, decisions} <- [
            {1, false, 1, 30},
            {2, false, 1, 30},
            {3, false, 1, 30},
            {4, false, 1, 30},
            {5, true, 1, 30},
            {6, true, 1, 30},
            {7, true, 1, 30},
            {8, true, 2, 30},
            {9, true, 2, 300}
          ] do
        graded("mmmmmm", number, answer({3.0, decisions}, {6.0, 30}))
        recorded("mmmmmm", number, if(won, do: "p1", else: "p2"), points: points)
      end

      body = home(conn)

      assert length(body["recent"]) == 1
      entry = hd(body["recent"])

      assert entry["id"] == "mmmmmm"
      assert entry["format"] == "Match to 7"
      assert entry["score"] == %{"yours" => 7, "theirs" => 4}
      assert entry["over"] == true
      assert entry["won"] == true
      assert entry["path"] == "/backgammon/mmmmmm/replay?game=1"

      # Nine games, newest first, each with its own rating and replay.
      assert Enum.map(entry["games"], & &1["game_number"]) == Enum.to_list(9..1//-1)
      assert hd(entry["games"])["path"] == "/backgammon/mmmmmm/replay?game=9"

      # 27.0 of error over 540 decisions, times 500. The mean of the nine
      # games' own ratings is 45.0 -- eight of them at 50.0 and the long
      # one at 5.0 -- which is what this deliberately is not.
      assert entry["decisions"] == 540
      assert entry["pr"] == 25.0
      assert Enum.sum(Enum.map(entry["games"], & &1["pr"])) / 9 == 45.0

      # The form still counts games, not rooms.
      assert body["form"]["games"] == 9
    end

    test "a match still being played says so, and shows where it stands", %{conn: conn} do
      {conn, user} = signed_in(conn, "playing@oskol.test")
      :ok = room("pppppp", user.id, 0, format: "match5", status: "playing")

      graded("pppppp", 1, answer({3.0, 30}, {6.0, 30}))
      recorded("pppppp", 1, "p1", points: 2)
      graded("pppppp", 2, answer({3.0, 30}, {6.0, 30}))
      recorded("pppppp", 2, "p2", points: 1)

      entry = hd(home(conn)["recent"])

      assert entry["format"] == "Match to 5"
      assert entry["over"] == false
      assert entry["won"] == nil
      assert entry["score"] == %{"yours" => 2, "theirs" => 1}
    end

    test "a match half graded shows the graded games and still says who won", %{conn: conn} do
      {conn, user} = signed_in(conn, "half@oskol.test")
      # The row says this account won it; the only graded game is one it
      # lost. The score says what it can see, and the verdict comes from
      # the row -- never from adding that score up.
      :ok = room("hhhhhh", user.id, 0, format: "match3", winners: ["p1"])
      graded("hhhhhh", 1, answer({3.0, 30}, {6.0, 30}))
      recorded("hhhhhh", 1, "p2", points: 1)
      :ok = Reviews.save("hhhhhh", 2, "pending", 1, nil, nil, nil, 30)

      entry = hd(home(conn)["recent"])

      assert length(entry["games"]) == 1
      assert entry["score"] == %{"yours" => 0, "theirs" => 1}
      assert entry["won"] == true
    end
  end

  describe "paging" do
    setup %{conn: conn} do
      {conn, user} = signed_in(conn, "paging@oskol.test")

      # Twelve rooms, newest last: each is one line of the list, and one
      # of them is a match of five games, so a page that counted games
      # would come out at a different length than a page that counts rooms.
      for i <- 1..12 do
        id = "p" <> String.pad_leading(Integer.to_string(i), 5, "0")
        :ok = room(id, user.id, 0, winners: ["p1"])

        games = if i == 12, do: 1..5, else: 1..1

        for number <- games do
          graded(id, number, answer({3.0, 30}, {6.0, 30}))
          recorded(id, number, "p1")
        end
      end

      # One room a day, oldest first: the review's own `inserted_at` is
      # what orders these and what the marker pages on.
      Repo.query!("""
      UPDATE game_reviews
      SET inserted_at = now() - (interval '1 day' * (13 - CAST(substring(game_id from 2) AS int)))
      WHERE game_id LIKE 'p0%'
      """)

      {:ok, conn: conn, user: user}
    end

    test "the home carries ten rooms and the next page carries on from it", %{conn: conn} do
      first = home(conn)
      assert length(first["recent"]) == 10
      assert first["more"] == true
      # Sixteen games behind twelve rooms: the form counts games.
      assert first["form"]["games"] == 16

      second =
        conn
        |> recycle()
        |> get(~p"/papi/me/games/graded?before=#{first["next"]}")
        |> json_response(200)

      assert length(second["rooms"]) == 2
      assert second["more"] == false
      assert second["next"] == nil

      # Twelve rooms in all, each shown once.
      seen = Enum.map(first["recent"] ++ second["rooms"], & &1["id"])
      assert length(Enum.uniq(seen)) == 12
    end

    test "a page never stops in the middle of a match", %{conn: conn} do
      # The five-game room is the newest, so it is the first line of the
      # first page -- and it carries all five of its games.
      first = home(conn)
      match = hd(first["recent"])

      assert match["id"] == "p00012"
      assert length(match["games"]) == 5

      second =
        conn
        |> recycle()
        |> get(~p"/papi/me/games/graded?before=#{first["next"]}")
        |> json_response(200)

      # No game of it turns up again on the next page.
      refute Enum.any?(second["rooms"], &(&1["id"] == "p00012"))
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

      # Both readings of these rows -- the form's, counting games, and the
      # recent list's, counting rooms -- have to reach the seats the same
      # way. A drift in either is a sequential scan over every game on the
      # site on a page a player opens.
      for {what, {sql, params}} <- [
            {"graded_for", Reviews.graded_for_sql(user.id, 10)},
            {"graded_rooms_for", Reviews.graded_rooms_for_sql(user.id, 10)},
            {"graded_rooms_for (paged)",
             Reviews.graded_rooms_for_sql(user.id, 10, {DateTime.utc_now(), "eown9"})}
          ] do
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
               "#{what} no longer reaches the seats through the players index:\n" <> plan
      end
    end
  end

  describe "the streak" do
    test "a game that finished today is a day, graded or not", %{conn: conn} do
      {conn, user} = signed_in(conn, "streak1@oskol.test")
      # No review at all: a game the engine never answered for is still a
      # day this player played.
      :ok = played_on("saaaaa", user.id, 0)

      assert home(conn)["form"]["streak"] == 1
    end

    test "a puzzle answered is a day too, and yesterday's still counts today", %{conn: conn} do
      {conn, user} = signed_in(conn, "streak2@oskol.test")
      :ok = practised_on(user.id, 1)

      # Nothing today, and it is not zero: until they are back, the streak
      # is what it stood at yesterday.
      assert home(conn)["form"]["streak"] == 1
    end

    test "the two sources are one run, not two", %{conn: conn} do
      {conn, user} = signed_in(conn, "streak3@oskol.test")
      # Two days ago a puzzle, yesterday a game, today a puzzle: three days
      # running, made of both kinds of day.
      :ok = practised_on(user.id, 2)
      :ok = played_on("sbbbbb", user.id, 1)
      :ok = practised_on(user.id, 0)

      assert home(conn)["form"]["streak"] == 3
    end

    test "a whole day missed ends it", %{conn: conn} do
      {conn, user} = signed_in(conn, "streak4@oskol.test")
      :ok = played_on("scccc1", user.id, 3)
      :ok = played_on("scccc2", user.id, 2)

      # Nothing yesterday and nothing today: the run is over, whatever it
      # was.
      assert home(conn)["form"]["streak"] == 0
    end

    test "an account that has never been here has none", %{conn: conn} do
      {conn, _user} = signed_in(conn, "streak5@oskol.test")
      assert home(conn)["form"]["streak"] == 0
    end
  end

  describe "what it costs" do
    @tag :slow
    test "a hundred graded games answer inside the budget", %{conn: conn} do
      {conn, user} = signed_in(conn, "budget@oskol.test")

      # Engine answers the size production stores: a turn-by-turn analysis
      # with its candidate moves, so the cost of reaching past one into the
      # totals is the real one. That reach is the expensive part of both
      # reads -- the stored answer has to be decompressed whole to get two
      # numbers out of it -- so what this measures is how many of them a
      # home load touches.
      turns = bulky_turns()

      # A hundred graded games behind the form, on a page of ten rooms: the
      # newest ten are a few games each, as a page of matches is, and the
      # rest are single games further back. The form reads all hundred; the
      # recent list reads only the ten rooms it draws.
      for r <- 1..10 do
        id = "bm" <> String.pad_leading(Integer.to_string(r), 4, "0")
        :ok = room(id, user.id, 0, format: "match3", winners: ["p1"])

        for number <- 1..3 do
          graded(id, number, answer({3.0, 30}, {6.0, 30}, turns: turns))
          recorded(id, number, "p1")
        end
      end

      for r <- 1..70 do
        id = "bs" <> String.pad_leading(Integer.to_string(r), 4, "0")
        :ok = room(id, user.id, 0, winners: ["p1"])
        graded(id, 1, answer({3.0, 30}, {6.0, 30}, turns: turns))
        recorded(id, 1, "p1")
      end

      # The matches are the newest, so they are the page.
      Repo.query!("""
      UPDATE game_reviews
      SET inserted_at = now() - interval '30 days'
      WHERE game_id LIKE 'bs%'
      """)

      # Warm the connection and the plan, then measure the request itself.
      # Five samples and the middle one: a single timing on a shared
      # machine says as much about the machine as about the page.
      body = home(conn)
      {ms, times} = median_ms(fn -> home(recycle(conn)) end)

      assert body["form"]["games"] == 100
      assert length(body["recent"]) == 10
      assert Enum.sum(Enum.map(body["recent"], &length(&1["games"]))) == 30

      bytes = byte_size(Jason.encode!(body))

      IO.puts(
        "\n  GET /papi/me/home, 100 graded games, a page of 10 rooms: " <>
          "#{Float.round(ms, 1)} ms median of #{inspect(Enum.map(times, &Float.round(&1, 1)))}, " <>
          "#{bytes} bytes"
      )

      assert ms < @budget_ms,
             "the home took #{Float.round(ms, 1)} ms with 100 graded games (budget #{@budget_ms} ms)"
    end

    @tag :slow
    test "a page of ten long sessions is still bounded", %{conn: conn} do
      {conn, user} = signed_in(conn, "heavy@oskol.test")
      turns = bulky_turns()

      # The heaviest page anybody can be served: ten rooms is the list, so
      # ten long unlimited sessions is the most games it can carry. Nothing
      # caps the games inside a room -- they are bounded by what two people
      # actually played -- so this is what that costs.
      for r <- 1..10 do
        id = "h" <> String.pad_leading(Integer.to_string(r), 5, "0")
        :ok = room(id, user.id, 0, format: "unlimited", winners: ["p1"])

        for number <- 1..10 do
          graded(id, number, answer({3.0, 30}, {6.0, 30}, turns: turns))
          recorded(id, number, "p1")
        end
      end

      body = home(conn)
      {ms, _} = median_ms(fn -> home(recycle(conn)) end)

      assert Enum.sum(Enum.map(body["recent"], &length(&1["games"]))) == 100
      bytes = byte_size(Jason.encode!(body))

      IO.puts(
        "\n  GET /papi/me/home, a page of 10 ten-game sessions: " <>
          "#{Float.round(ms, 1)} ms median, #{bytes} bytes"
      )

      # Both reads touch all hundred stored answers here, which is twice
      # what the budget case pays. It is a page nobody has yet; what this
      # holds is the shape of the cost, so a change that made it seconds or
      # megabytes fails here.
      assert ms < 400, "the heaviest page took #{Float.round(ms, 1)} ms"
      assert bytes < 100_000, "the heaviest page was #{bytes} bytes"
    end
  end

  # Five runs, the middle one, and all of them for the eye.
  defp median_ms(work) do
    times =
      for _ <- 1..5 do
        {us, _} = :timer.tc(work)
        us / 1000
      end

    {Enum.at(Enum.sort(times), 2), times}
  end

  # A finished game of this account's, `days` local days ago: the row the
  # streak reads is the record written when a game ends.
  defp played_on(game_id, user_id, days) do
    :ok = room(game_id, user_id, 0, winners: ["p1"])
    :ok = recorded(game_id, 1, "p1")

    at = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.query!("UPDATE game_records SET inserted_at = $1 WHERE game_id = $2", [
      DateTime.to_naive(at),
      game_id
    ])

    :ok
  end

  # A puzzle answered `days` local days ago. Retain refuses a review dated
  # before the card it is for, so the answer is made now and the row moved
  # back -- which is the column the streak reads either way.
  defp practised_on(user_id, days) do
    {:ok, _} = Retain.put_user(user_id, tz: "Etc/UTC")
    key = "streak-#{days}"
    {:ok, _} = Retain.put_items(user_id, [%{key: key, tags: %{}, content: %{}}])
    {:ok, %{review_id: review_id}} = Retain.review(user_id, key, :pass)

    at = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.query!("UPDATE retain_reviews SET at = $1 WHERE id = $2", [
      DateTime.to_naive(at),
      review_id
    ])

    :ok
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
