defmodule OskolWeb.Api.PracticeApiTest do
  @moduledoc """
  The wiring behind a practice session: the routes, the envelope, the
  statuses, and who each of them answers.

  What a session decides -- due before new, a guest's own mistakes, which
  names are timezone names -- is tested in Gleam
  (test/oskol/practice_session_test.gleam). What is here is what only a
  real request can show: that the four routes exist, that a guest's session
  reaches the database as that guest, and that the writes need a CSRF token
  like every other `/papi` write.
  """
  # Guest rows and decks are written from the request process: shared
  # sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp csrf_checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> csrf_checked()
    |> put_req_header("x-csrf-token", token)
  end

  defp a_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # A browser that has been here before, signed into this account.
  defp signed_in(conn, email) do
    guest_id = a_guest_id()
    user = Auth.find_or_create_user(email)
    conn = conn |> as_guest(guest_id) |> get(~p"/")
    :ok = Auth.bind_guest(guest_id, user.id)
    {recycle(conn), user}
  end

  # One mistake of this grade, on a seat this account owns, written the way
  # the review job writes it. Returns the puzzle id.
  defp a_mistake(user_id, grade, n) do
    game_id = "pa-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    Repo.insert!(%Oskol.Persistence.Game{
      id: game_id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: [%{"id" => "p1", "name" => "p1", "guest_id" => "g1", "user_id" => user_id}],
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    :ok = Oskol.Reviews.save(game_id, 1, "done", 1, %{"turns" => []}, nil, %{"turns" => []}, 3)
    base = :crypto.hash(:sha256, game_id) |> Base.encode32(padding: false) |> binary_part(0, 7)

    {:ok, _} =
      Oskol.Puzzles.store(
        game_id,
        1,
        [
          %{
            key: "k-#{game_id}",
            ids: for(m <- 1..4, do: base <> Integer.to_string(m)),
            kind: "move",
            question: %{
              "version" => 1,
              "kind" => "move",
              "board" => List.duplicate(0, 26) |> List.replace_at(n, 2),
              "dice" => [6, 4],
              "cube" => %{"value" => 1, "owner" => "center"},
              "score" => nil,
              "crawford" => false,
              "jacoby" => false
            },
            answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
            evaluated_by: %{"levels" => %{}},
            complete: true
          }
        ],
        [
          %{
            key: "k-#{game_id}",
            game_number: 1,
            turn: 1,
            kind: "move",
            seat: 0,
            player_id: "p1",
            played: "13/8 13/11",
            equity_lost: 0.1,
            grade: grade,
            skipped_reason: nil
          }
        ]
      )

    Repo.one!(from(s in Oskol.Puzzles.Source, where: s.game_id == ^game_id, select: s.puzzle_id))
  end

  describe "GET /papi/practice" do
    test "a stranger is given an empty session and not an error", %{conn: conn} do
      body = conn |> get(~p"/papi/practice") |> json_response(200)

      assert %{"ok" => true, "puzzles" => [], "cursor" => nil, "counts" => nil, "game" => nil} =
               body
    end

    test "a guest with no games has nothing to practice, and no deck is made", %{conn: conn} do
      body = conn |> get(~p"/papi/practice") |> json_response(200)
      assert body["puzzles"] == []
      # Guests never get a deck, whatever they ask for.
      assert Repo.aggregate(Retain.User, :count) == 0
    end

    test "an account with no mistakes yet gets an empty session, not a crash", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")

      body = conn |> get(~p"/papi/practice") |> json_response(200)
      assert body["puzzles"] == []
      assert body["counts"] == %{"due" => 0, "new_today" => 0, "new_tomorrow" => 0, "deck" => 0}
      # Reading a session must not open a deck for an account that has none.
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end

    test "a backlog is a backlog, and never a target", %{conn: conn} do
      # Twenty-three cards due. The day says only what has been answered:
      # there is no target on the wire, so nothing can be behind on one.
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")

      keys = Enum.map(1..23, &"puzzle-#{&1}")

      {:ok, _} =
        Retain.put_items(user.id, Enum.map(keys, &%{key: &1, tags: %{}, content: %{}}))

      {:ok, _} = Retain.start(user.id, keys)

      body = conn |> get(~p"/papi/practice") |> json_response(200)

      assert body["counts"]["due"] == 23
      assert body["today"] == %{"done" => 0}
    end

    test "a band asks for one tier, and a band that is not one is refused", %{conn: conn} do
      # The cards themselves are nobody's band (no `puzzle_sources` row),
      # so the queue is empty either way; what this pins is that the
      # whitelist is the server's and a made-up band cannot widen it.
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")

      for band <- ["very_bad", "bad", "doubtful"] do
        body = conn |> get("/papi/practice?band=" <> band) |> json_response(200)
        assert body["puzzles"] == []
      end

      body = conn |> get("/papi/practice?band=brilliant") |> json_response(422)
      assert body["ok"] == false
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["message"] == "That is not one of your mistake tiers."
    end

    test "a session is never paged, whatever the query string says", %{conn: conn} do
      # There is no offset any more: the due set is live, so every fetch is
      # the front of the queue. A left-over `?offset=` from an old client
      # is ignored rather than reaching the database -- a number too big
      # for a bigint used to come back as a 500.
      for query <- ["", "?offset=20", "?offset=99999999999999999999", "?offset=nonsense"] do
        body = conn |> get("/papi/practice" <> query) |> json_response(200)
        assert body["puzzles"] == []
        assert body["cursor"] == nil
      end
    end
  end

  describe "the five decks" do
    test "an account with nothing yet reads three empty tiers, and no set is offered unbuilt",
         %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")

      body = conn |> get(~p"/papi/practice/decks") |> json_response(200)
      # No set has been built in this database, so none is offered.
      assert Enum.map(body["decks"], & &1["id"]) == ["very_bad", "bad", "doubtful"]

      assert Enum.all?(body["decks"], fn d ->
               d["joined"] == false and d["size"] == 0 and d["cost"] == nil and
                 d["standing"]["levels"] == [0, 0, 0, 0, 0, 0, 0, 0]
             end)

      # No graded game behind it: nothing to say what mistakes cost, read
      # off the real rows (graded_for and mistake_costs both ran).
      assert %{"lead" => nil, "today" => %{"done" => 0}, "streak" => 0, "cost_all" => nil} =
               body

      page = conn |> get(~p"/papi/practice/decks/dubious") |> json_response(200)
      assert %{"deck" => %{"id" => "doubtful", "mark" => "?!"}, "cells" => []} = page
      assert page["days"] == List.duplicate(false, 30)

      # A set nobody built, and a slug that names nothing: the same 404.
      assert %{"error" => %{"code" => "not_found"}} =
               conn |> get(~p"/papi/practice/decks/openings") |> json_response(404)

      assert conn |> get(~p"/papi/practice/decks/doubtful") |> json_response(404)

      # Reading opened no deck.
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end

    test "KEEP GOING takes a band, and refuses one that is not", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC", new_per_day: 3)

      bad = a_mistake(user.id, "bad", 1)
      worse = a_mistake(user.id, "very_bad", 2)
      assert {:ok, 2} = Oskol.Practice.sync(user.id)
      # The day's budget is nothing, set after the sync (which opens the
      # deck at the pace).
      {:ok, _} = Retain.put_user(user.id, new_per_day: 0)
      # The ordinary queue offers no new one.
      assert conn |> get("/papi/practice?band=bad") |> json_response(200) |> Map.get("puzzles") ==
               []

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/more", %{"band" => "bad"})
        |> json_response(200)

      # The bad one was started, over the budget, and is the session now;
      # the very bad one was left alone.
      assert [%{"id" => ^bad, "due" => true}] = body["puzzles"]
      {:ok, started} = Retain.fetch_item(user.id, bad)
      assert started.started_at
      {:ok, untouched} = Retain.fetch_item(user.id, worse)
      assert untouched.started_at == nil

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn
               |> with_csrf()
               |> post(~p"/papi/practice/more", %{"band" => "brilliant"})
               |> json_response(422)
    end

    test "PRACTICE ANYWAY answers the rotation, soonest due first, once nothing is due",
         %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")

      {:ok, _} =
        Retain.put_items(user.id, Enum.map(["a", "b"], &%{key: &1, tags: %{}, content: %{}}))

      {:ok, _} = Retain.start(user.id, ["a", "b"])
      # Both back tomorrow; b was answered first, so b is due first.
      {:ok, _} = Retain.review(user.id, "b", :again)
      {:ok, _} = Retain.review(user.id, "a", :pass)

      assert conn |> get(~p"/papi/practice") |> json_response(200) |> Map.get("puzzles") == []

      anyway = conn |> get("/papi/practice?all=1") |> json_response(200)
      assert Enum.map(anyway["puzzles"], & &1["id"]) == ["b", "a"]
      assert Enum.all?(anyway["puzzles"], &(&1["due"] == false))

      # Nothing moved by reading.
      {:ok, a} = Retain.fetch_item(user.id, "a")
      assert a.level == 1
    end
  end

  describe "POST /papi/practice/tz" do
    test "an account's browser writes its zone once", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/tz", %{"tz" => "America/Vancouver"})
        |> json_response(200)

      assert body["ok"] == true
      {:ok, deck} = Retain.fetch_user(user.id)
      assert deck.tz == "America/Vancouver"
    end

    test "a name that is not a zone is 422 and writes nothing", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/tz", %{"tz" => "Mars/Olympus"})
        |> json_response(422)

      assert %{"ok" => false, "error" => %{"code" => "validation_failed"}} = body
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end

    test "a guest has no deck to put a zone on", %{conn: conn} do
      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/tz", %{"tz" => "America/Vancouver"})
        |> json_response(409)

      assert %{"ok" => false, "error" => %{"code" => "not_in_rotation"}} = body
    end
  end

  describe "POST /papi/practice/bury" do
    test "a puzzle that is not in the deck is a 404", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/bury", %{"id" => "nosuch"})
        |> json_response(404)

      assert %{"ok" => false, "error" => %{"code" => "not_found"}} = body
    end

    test "a puzzle in the deck but not in rotation is a 409", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")
      {:ok, _} = Retain.put_items(user.id, [%{key: "aaa", tags: %{}, content: %{}}])

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/bury", %{"id" => "aaa"})
        |> json_response(409)

      assert %{"ok" => false, "error" => %{"code" => "not_in_rotation"}} = body
    end

    test "a puzzle in rotation comes back tomorrow at the deck's own midnight", %{conn: conn} do
      {conn, user} = signed_in(conn, "arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Pacific/Auckland")
      {:ok, _} = Retain.put_items(user.id, [%{key: "aaa", tags: %{}, content: %{}}])
      {:ok, _} = Retain.start(user.id, ["aaa"])

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/bury", %{"id" => "aaa"})
        |> json_response(200)

      expected =
        Retain.Clock.start_of_tomorrow(DateTime.utc_now(), "Pacific/Auckland")
        |> DateTime.to_unix(:millisecond)

      assert body["due"] == expected
      # The level is kept: burying is not an answer.
      assert body["level"] == 0
    end
  end

  describe "POST /papi/practice/more" do
    test "KEEP GOING answers a session for an account with nothing in its deck", %{conn: conn} do
      {conn, _user} = signed_in(conn, "arie@oskol.test")

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/practice/more", %{})
        |> json_response(200)

      assert body["puzzles"] == []
    end

    test "the writes need a CSRF token like every other /papi write", %{conn: conn} do
      conn = get(conn, ~p"/") |> recycle() |> csrf_checked()

      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        post(conn, ~p"/papi/practice/tz", %{"tz" => "Etc/UTC"})
      end
    end
  end
end
