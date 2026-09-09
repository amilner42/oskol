defmodule OskolWeb.Api.LandingApiTest do
  @moduledoc """
  The JSON contract the Elm client is written against. The decisions behind
  these responses are tested in Gleam (test/oskol/landing_handler_test.gleam
  and rooms_handler_test.gleam); this locks the wiring: routes, envelope,
  status codes, CSRF, guest identity, and a room that really starts.
  """
  # Guest rows are written from the request process and game rows from the
  # persister's: shared sandbox, not async.
  use OskolWeb.ConnCase, async: false

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.Game.Persister
  alias Oskol.Guests
  alias Oskol.Repo

  @cookie "_oskol_guest"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  defp new_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp as_guest(conn, guest_id), do: put_req_cookie(conn, @cookie, guest_id)

  # Phoenix's test conns skip forgery protection; these turn it back on, so
  # the pipeline itself is what is under test.
  defp csrf_checked(conn), do: Plug.Conn.put_private(conn, :plug_skip_csrf_protection, false)

  # A browser gets its CSRF token from the page it is served; the Elm client
  # sends it back in `x-csrf-token`.
  defp with_csrf(conn) do
    page = get(conn, ~p"/")
    [_, token] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(page, 200))

    page
    |> recycle()
    |> csrf_checked()
    |> put_req_header("x-csrf-token", token)
  end

  # ---------- GET /papi/library ----------

  test "the library lists every registered game", %{conn: conn} do
    body = conn |> get(~p"/papi/library") |> json_response(200)

    assert %{"ok" => true, "games" => games, "coming_soon" => []} = body

    slugs = Enum.map(games, & &1["slug"])
    assert "poker" in slugs
    assert "backgammon" in slugs

    backgammon = Enum.find(games, &(&1["slug"] == "backgammon"))
    assert backgammon["name"] == "Backgammon"
    assert is_binary(backgammon["tagline"])
  end

  test "the library serves the same game maps the page assigns", %{conn: conn} do
    body = conn |> get(~p"/papi/library") |> json_response(200)

    assert body["games"] == Oskol.GameKit.games()
  end

  test "a returning guest's remembered name rides along", %{conn: conn} do
    guest_id = new_guest_id()
    :ok = Guests.save_name(guest_id, "Renée")

    body = conn |> as_guest(guest_id) |> get(~p"/papi/library") |> json_response(200)

    assert body["guest"] == %{"name" => "Renée"}
  end

  test "a visitor we have never seen is minted a guest cookie", %{conn: conn} do
    conn = get(conn, ~p"/papi/library")

    assert json_response(conn, 200)["guest"] == %{"name" => nil}
    assert %{value: id} = conn.resp_cookies[@cookie]
    assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
  end

  # ---------- GET /papi/games/:slug ----------

  test "a game page carries its copy and its formats", %{conn: conn} do
    body = conn |> get(~p"/papi/games/backgammon") |> json_response(200)

    assert %{"ok" => true, "game" => game, "formats" => formats} = body

    assert game["slug"] == "backgammon"
    assert game["name"] == "Backgammon"
    assert game["title"] =~ "backgammon"
    assert is_binary(game["intro"])
    assert is_binary(game["meta_description"])
    assert length(game["rules"]) > 0
    assert [%{"question" => _, "answer" => _} | _] = game["faq"]
    assert game["min_players"] == 2
    assert game["max_players"] == 2
    assert is_binary(game["default_clock"])
    assert [%{"id" => _, "name" => _, "description" => _} | _] = game["clocks"]

    assert [%{"id" => _, "name" => _, "description" => _, "settings" => _} | _] = formats
    assert Enum.map(formats, & &1["id"]) == Oskol.GameKit.format_ids("backgammon")
  end

  test "an unknown game is a not_found envelope", %{conn: conn} do
    body = conn |> get(~p"/papi/games/checkers") |> json_response(404)

    assert %{
             "ok" => false,
             "error" => %{"code" => "not_found", "message" => "Unknown game: checkers"}
           } = body
  end

  # ---------- POST /papi/games/:slug ----------

  test "creating a game mints a room and seats the creator", %{conn: conn} do
    guest_id = new_guest_id()

    conn =
      conn
      |> as_guest(guest_id)
      |> with_csrf()
      |> post(~p"/papi/games/backgammon", %{"format" => "single", "name" => " Alice "})

    assert %{"ok" => true, "id" => game_id, "path" => path} = json_response(conn, 200)
    assert game_id =~ ~r/^\d{6}$/
    assert path == "/backgammon/#{game_id}"

    # A real room, set up as the start page would have set it up, with the
    # trimmed name in its one taken seat.
    assert {:ok, _pid} = Game.lookup_game(game_id)
    state = Game.get_server_state(game_id)
    assert state.slug == "backgammon"
    assert state.setup.format == "single"
    assert [{_id, "Alice"}] = GameServerState.seats(state)

    # The seat has no live connection: nothing was there to monitor.
    assert [%{connected: false, guest_id: ^guest_id}] = Map.values(state.connections)

    # And the guest is remembered, exactly as the LiveView remembers them.
    assert Repo.get(Guests.Guest, guest_id).name == "Alice"
  end

  test "a game with no name is refused with the page's own message", %{conn: conn} do
    conn =
      conn
      |> with_csrf()
      |> post(~p"/papi/games/backgammon", %{"format" => "single", "name" => "   "})

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "validation_failed",
               "message" => "Pick a display name first"
             }
           } = json_response(conn, 422)
  end

  test "a name nobody could read is refused", %{conn: conn} do
    conn =
      conn
      |> with_csrf()
      |> post(~p"/papi/games/backgammon", %{
        "format" => "single",
        "name" => "1234567890123456789012345"
      })

    assert json_response(conn, 422)["error"]["message"] == "Names are 24 characters at most"
  end

  test "a mode the game has not got is refused", %{conn: conn} do
    conn =
      conn
      |> with_csrf()
      |> post(~p"/papi/games/backgammon", %{"format" => "nope", "name" => "Alice"})

    assert json_response(conn, 422)["error"]["message"] == "Unknown game mode"
  end

  test "a missing format is the same refusal", %{conn: conn} do
    conn = conn |> with_csrf() |> post(~p"/papi/games/backgammon", %{"name" => "Alice"})

    assert json_response(conn, 422)["error"]["message"] == "Unknown game mode"
  end

  test "creating a game of a game that does not exist is a 404", %{conn: conn} do
    conn =
      conn
      |> with_csrf()
      |> post(~p"/papi/games/checkers", %{"format" => "single", "name" => "Alice"})

    assert json_response(conn, 404)["error"]["code"] == "not_found"
  end

  test "a post with no CSRF token is refused", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> csrf_checked()
      |> post(~p"/papi/games/backgammon", %{"format" => "single", "name" => "Alice"})
    end
  end

  test "a post carrying the token in x-csrf-token is let through", %{conn: conn} do
    conn =
      conn
      |> with_csrf()
      |> post(~p"/papi/games/backgammon", %{"format" => "single", "name" => "Alice"})

    assert json_response(conn, 200)["ok"] == true
  end
end
