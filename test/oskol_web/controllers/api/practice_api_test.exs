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

  describe "GET /papi/practice" do
    test "a stranger is given an empty session and not an error", %{conn: conn} do
      body = conn |> get(~p"/papi/practice") |> json_response(200)

      assert %{"ok" => true, "puzzles" => [], "cursor" => nil, "counts" => nil, "game" => nil} =
               body
    end

    test "a guest with no games has nothing to practise, and no deck is made", %{conn: conn} do
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
