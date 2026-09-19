defmodule OskolWeb.Api.LandingApiTest do
  @moduledoc """
  The JSON contract the Elm client is written against. The decisions behind
  these responses are tested in Gleam (test/oskol/landing_handler_test.gleam
  and rooms_handler_test.gleam); this locks the wiring: routes, envelope,
  status codes, CSRF, guest identity, and rooms that really start.
  """
  # Guest rows are written from the request process and game rows from the
  # persister's: shared sandbox, not async.
  use OskolWeb.ConnCase, async: false

  import Ecto.Query

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.Game.GameSupervisor
  alias Oskol.Game.Persister
  alias Oskol.GameFixtures
  alias Oskol.Guests
  alias Oskol.Persistence
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

  # Phoenix's test conns skip forgery protection; this turns it back on, so
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

  defp create(conn, params) do
    conn |> post(~p"/papi/games/backgammon", params) |> json_response(200)
  end

  defp game_row(game_id) do
    Persister.flush()
    Repo.get(Persistence.Game, game_id)
  end

  # ---------- GET /papi/library ----------

  describe "GET /papi/library" do
    test "lists every registered game", %{conn: conn} do
      body = conn |> get(~p"/papi/library") |> json_response(200)

      assert %{"ok" => true, "games" => games, "coming_soon" => []} = body

      assert Enum.map(games, & &1["slug"]) == ["backgammon"]

      backgammon = Enum.find(games, &(&1["slug"] == "backgammon"))
      assert backgammon["name"] == "Backgammon"
      assert is_binary(backgammon["tagline"])
    end

    test "serves the same game maps the catalogue holds", %{conn: conn} do
      body = conn |> get(~p"/papi/library") |> json_response(200)

      assert body["games"] == Oskol.GameKit.games()
    end

    test "a returning guest's remembered name rides along", %{conn: conn} do
      guest_id = new_guest_id()
      :ok = Guests.save_name(guest_id, "Renée")

      body = conn |> as_guest(guest_id) |> get(~p"/papi/library") |> json_response(200)

      assert body["guest_name"] == "Renée"
    end

    test "a visitor we have never seen is minted a guest cookie", %{conn: conn} do
      conn = get(conn, ~p"/papi/library")

      assert json_response(conn, 200)["guest_name"] == nil
      assert %{value: id} = conn.resp_cookies[@cookie]
      assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
    end
  end

  # ---------- GET /papi/games/:slug ----------

  describe "GET /papi/games/:slug" do
    test "carries the game, its formats, the clock presets and its copy", %{conn: conn} do
      body = conn |> get(~p"/papi/games/backgammon") |> json_response(200)

      assert %{"ok" => true, "game" => game, "formats" => formats, "copy" => copy} = body

      assert game["slug"] == "backgammon"
      assert game["name"] == "Backgammon"
      assert game["min_players"] == 2
      assert game["max_players"] == 2
      # The game names the presets it offers; the presets come with the page.
      assert is_binary(game["default_clock"])
      assert Enum.all?(game["clocks"], &is_binary/1)
      assert [%{"id" => "none", "name" => _, "description" => _} | _] = body["clock_presets"]
      assert Enum.all?(game["clocks"], fn id -> id in Oskol.GameKit.clock_ids() end)

      assert [%{"id" => _, "name" => _, "description" => _} | _] = formats
      assert Enum.map(formats, & &1["id"]) == Oskol.GameKit.format_ids("backgammon")

      assert copy["title"] =~ "backgammon"
      assert is_binary(copy["description"])
      assert is_binary(copy["intro"])
      assert length(copy["rules"]) > 0
      assert [%{"question" => _, "answer" => _} | _] = copy["faq"]
    end

    test "the guest's name reaches the create form", %{conn: conn} do
      guest_id = new_guest_id()
      :ok = Guests.save_name(guest_id, "Renée")

      body = conn |> as_guest(guest_id) |> get(~p"/papi/games/backgammon") |> json_response(200)

      assert body["guest_name"] == "Renée"
    end

    test "an unknown game is a not_found envelope", %{conn: conn} do
      body = conn |> get(~p"/papi/games/checkers") |> json_response(404)

      assert %{
               "ok" => false,
               "error" => %{"code" => "not_found", "message" => "No game with that name"}
             } = body
    end

    test "the games Oskol no longer hosts are not_found too", %{conn: conn} do
      for slug <- ~w(poker go chess) do
        body = conn |> get(~p"/papi/games/#{slug}") |> json_response(404)
        assert body["error"]["code"] == "not_found", slug
      end
    end
  end

  # ---------- POST /papi/games/:slug ----------

  describe "POST /papi/games/:slug" do
    test "mints a room, seats the creator and hands out the seat's URL", %{conn: conn} do
      guest_id = new_guest_id()

      body =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> create(%{"format" => "single", "name" => " Alice ", "clock" => "none"})

      assert %{"ok" => true, "id" => game_id, "path" => path, "player_id" => player_id} = body
      # Six characters of the code alphabet: the digits and the letters left
      # after the four lookalikes are dropped.
      assert game_id =~ ~r/^[0-9A-HJKMNP-TV-Z]{6}$/

      # A real room, with the trimmed name in its one taken seat, and a path
      # that is just the room: the seat is held by the guest that took it.
      assert {:ok, _pid} = Game.lookup_game(game_id)
      state = Game.get_server_state(game_id)
      assert state.slug == "backgammon"
      assert [{^player_id, "Alice"}] = GameServerState.seats(state)
      assert path == "/backgammon/#{game_id}"
      assert GameServerState.guest_for(state, player_id) == guest_id

      # The seat has no live connection until the browser opens that link.
      assert [%{connected: false, guest_id: ^guest_id}] = Map.values(state.connections)
    end

    test "the creator's mode and clock configure the room", %{conn: conn} do
      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon", %{
          "format" => "match5",
          "name" => "Alice",
          "clock" => "bg10"
        })
        |> json_response(200)

      state = Game.get_server_state(body["id"])
      assert state.setup.format == "match5"
      assert state.setup.clock == "bg10"
      assert GameServerState.summary(state) =~ "10 min clock"
    end

    test "a clock the game does not offer is refused", %{conn: conn} do
      conn =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon", %{
          "format" => "single",
          "name" => "Alice",
          "clock" => "sudden_death"
        })

      assert json_response(conn, 422)["error"]["message"] == "Unknown time control"
    end

    test "a stray selections key from an older client is ignored", %{conn: conn} do
      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon", %{
          "format" => "single",
          "name" => "Alice",
          "clock" => "none",
          "selections" => %{"twist" => "pick_dice"}
        })
        |> json_response(200)

      state = Game.get_server_state(body["id"])
      assert state.setup.format == "single"
      refute Map.has_key?(state.setup, :selections)
    end

    test "no clock asked for means the game's default", %{conn: conn} do
      body = conn |> with_csrf() |> create(%{"format" => "single", "name" => "Alice"})

      state = Game.get_server_state(body["id"])
      {:ok, info} = Oskol.GameKit.game_info("backgammon")
      assert state.setup.clock == info["default_clock"]
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
  end

  # ---------- GET /papi/games/:slug/rooms/:id ----------

  describe "GET /papi/games/:slug/rooms/:id" do
    test "a free seat is an open invite, with who is waiting and what for", %{conn: conn} do
      %{game_id: game_id} = GameFixtures.lobby("match3", clock: "bg3", pid1: self())

      body = conn |> get(~p"/papi/games/backgammon/rooms/#{game_id}") |> json_response(200)

      assert %{"ok" => true, "state" => "open", "inviter_name" => "Alice"} = body
      assert body["summary"] == "Match to 3 · 3 min clock"
      assert body["disconnected"] == []
    end

    test "a table with both players at it offers nothing", %{conn: conn} do
      %{game_id: game_id} = GameFixtures.started(42, "single", pid1: self(), pid2: idle_player())

      body = conn |> get(~p"/papi/games/backgammon/rooms/#{game_id}") |> json_response(200)

      assert body["state"] == "full"
      assert body["disconnected"] == []
    end

    test "a seat whose player went away is offered back by name", %{conn: conn} do
      player = idle_player()
      fixture = GameFixtures.started(42, "single", pid1: self(), pid2: player)
      stop_player(fixture.game_id, player)

      body =
        conn |> get(~p"/papi/games/backgammon/rooms/#{fixture.game_id}") |> json_response(200)

      assert body["state"] == "away"
      assert body["disconnected"] == [%{"id" => fixture.p2, "name" => "Bob"}]
    end

    test "a code no room answers to is missing", %{conn: conn} do
      body = conn |> get(~p"/papi/games/backgammon/rooms/000000") |> json_response(200)

      assert body == %{
               "ok" => true,
               "state" => "missing",
               "inviter_name" => nil,
               "summary" => nil,
               "disconnected" => []
             }
    end
  end

  # ---------- POST /papi/games/:slug/rooms/:id ----------

  describe "POST /papi/games/:slug/rooms/:id" do
    test "a name takes the free seat and starts the game", %{conn: conn} do
      %{game_id: game_id, p1: p1} = GameFixtures.lobby("single", pid1: self())

      body =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/#{game_id}", %{"name" => "Bob"})
        |> json_response(200)

      assert %{"ok" => true, "id" => ^game_id, "player_id" => p2} = body
      refute p2 == p1

      state = Game.get_server_state(game_id)
      assert body["path"] == "/backgammon/#{game_id}"
      # The table filled up, so the game started.
      assert state.instance != nil
    end

    test "a browser already at the table cannot take a second seat", %{conn: conn} do
      # One guest id names one seat: a creator who opens their own invite
      # link is told so rather than handed a seat they could never reach.
      guest_id = new_guest_id()

      %{"id" => game_id} =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> create(%{"format" => "single", "name" => "Alice", "clock" => "none"})

      again =
        build_conn()
        |> as_guest(guest_id)
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/#{game_id}", %{"name" => "Alice again"})

      assert json_response(again, 422)["error"]["message"] == "You are already at this table"
    end

    test "a name already at the table is refused", %{conn: conn} do
      %{game_id: game_id} = GameFixtures.lobby("single", pid1: self())

      conn =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/#{game_id}", %{"name" => "Alice"})

      assert json_response(conn, 422)["error"]["message"] == "That name is already taken"
    end

    test "joining never creates a room", %{conn: conn} do
      conn =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/424242", %{"name" => "Bob"})

      assert json_response(conn, 404)["error"]["message"] ==
               "That game is over. Start a new one and send a fresh link."

      assert Game.lookup_game("424242") == :not_found
    end

    test "a player id takes a seat back, and the claiming guest holds it", %{conn: conn} do
      player = idle_player()
      fixture = GameFixtures.started(42, "single", pid1: self(), pid2: player)
      stop_player(fixture.game_id, player)
      claimer = GameFixtures.unique_guest_id()

      body =
        conn
        |> as_guest(claimer)
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/#{fixture.game_id}", %{
          "player_id" => fixture.p2
        })
        |> json_response(200)

      assert body["player_id"] == fixture.p2
      # Nothing secret comes back; the seat is this browser's from here, and
      # the browser that held it before holds it no longer.
      assert body["path"] == "/backgammon/#{fixture.game_id}"
      assert GameFixtures.guest_for(fixture.game_id, fixture.p2) == claimer
      refute GameFixtures.guest_for(fixture.game_id, fixture.p2) == fixture.g2
    end

    test "a seat whose player is back at the table is not up for grabs", %{conn: conn} do
      fixture = GameFixtures.started(42, "single", pid1: self(), pid2: idle_player())

      conn =
        conn
        |> with_csrf()
        |> post(~p"/papi/games/backgammon/rooms/#{fixture.game_id}", %{
          "player_id" => fixture.p2
        })

      assert json_response(conn, 422)["error"]["message"] == "That player is back at the table"
    end
  end

  # ---------- GET /papi/games/:slug/rooms/:id/record ----------

  describe "GET /papi/games/:slug/rooms/:id/record" do
    test "a seat reads the game's whole record", %{conn: conn} do
      %{game_id: game_id, g2: g2} = GameFixtures.started(42, "match5")

      body =
        conn
        |> as_guest(g2)
        |> get(~p"/papi/games/backgammon/rooms/#{game_id}/record")
        |> json_response(200)

      assert body["seated"] == true

      assert %{"ok" => true, "slug" => "backgammon", "id" => ^game_id, "record" => record} = body

      # Nothing has been committed yet, so there is no game to list; the
      # match's length, its players and the position games start from are
      # all there.
      assert %{"target" => 5, "cube" => true, "players" => [_, _], "games" => []} = record
      assert %{"white" => %{"pips" => 167}} = record["start"]
    end

    test "anyone with the room reads the record; only the seat it faces changes",
         %{conn: conn} do
      %{game_id: game_id, g1: g1} = GameFixtures.started(42, "match5")

      seated =
        conn
        |> as_guest(g1)
        |> get("/papi/games/backgammon/rooms/#{game_id}/record")
        |> json_response(200)

      # A replay is what both players already saw, so it opens for anyone
      # with the link. A reader holding no seat here gets the same record,
      # facing the seat that played first, and turns the board around
      # themselves. An old link's `?t=` is not read at all.
      for asker <- [
            &as_guest(&1, GameFixtures.unique_guest_id()),
            & &1
          ],
          query <- ["", "?t=an-old-token"] do
        body =
          conn
          |> asker.()
          |> get("/papi/games/backgammon/rooms/#{game_id}/record#{query}")
          |> json_response(200)

        assert body["record"] == seated["record"]
        assert body["seated"] == false
        assert body["you"] == hd(seated["record"]["players"])["id"]
      end
    end

    test "a room that does not exist is not found and says nothing more", %{conn: conn} do
      body =
        conn
        |> get("/papi/games/backgammon/rooms/999999/record")
        |> json_response(404)

      assert body["error"] == %{"code" => "not_found", "message" => "No record for that game"}
    end
  end

  # ---------- GET /papi/codes/:code ----------

  describe "GET /papi/codes/:code" do
    test "a live code resolves to the game it belongs to", %{conn: conn} do
      %{game_id: game_id} = GameFixtures.lobby("single", pid1: self())

      assert %{"ok" => true, "slug" => "backgammon"} =
               conn |> get(~p"/papi/codes/#{game_id}") |> json_response(200)
    end

    test "a code with no room is not found", %{conn: conn} do
      body = conn |> get(~p"/papi/codes/000000") |> json_response(404)

      assert body["error"] == %{"code" => "not_found", "message" => "No game with that code"}
    end
  end

  # ---------- /papi/me/games ----------

  describe "GET /papi/me/games" do
    test "a visitor with no seat anywhere has nothing to resume", %{conn: conn} do
      body = conn |> as_guest(new_guest_id()) |> get(~p"/papi/me/games") |> json_response(200)
      assert body == %{"ok" => true, "games" => []}
    end

    test "lists the games this browser's guest can pick back up, from the rows", %{conn: conn} do
      %{game_id: game_id, p1: alice_seat, p2: bob_seat, g1: alice, mover: mover} =
        GameFixtures.started(42, "match5", clock: "bg5")

      Persister.flush()
      # Nothing here needs the room: a cold row answers the same.
      {:ok, pid} = GameSupervisor.find_game(game_id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      body = conn |> as_guest(alice) |> get(~p"/papi/me/games") |> json_response(200)

      assert %{"ok" => true, "games" => [game]} = body
      assert game["id"] == game_id
      assert game["path"] == "/backgammon/#{game_id}"
      assert game["status"] == "playing"
      assert game["opponent"] == "Bob"
      assert game["format"] == "Match to 5"
      assert game["clock"] == "5 min"
      # Whose move it is comes from the snapshot the room wrote.
      assert game["your_move"] == (mover == alice_seat)
      # The clocks as the row last saw them: 5 min each, the mover's running
      # with the 12 s delay still ahead of it.
      assert %{"mine_ms" => 300_000, "theirs_ms" => 300_000, "free_ms" => 12_000} = game["time"]
      assert game["time"]["running"] == if(mover == alice_seat, do: "mine", else: "theirs")
      assert is_integer(game["time"]["age_s"])
      assert is_integer(game["idle_s"])
      # And asking woke nothing.
      assert :error = GameSupervisor.find_game(game_id)
      _ = bob_seat
    end
  end

  # ---------- /papi/me/prefs ----------

  describe "GET and POST /papi/me/prefs" do
    test "a visitor who has never picked anything has no preferences", %{conn: conn} do
      body = conn |> as_guest(new_guest_id()) |> get(~p"/papi/me/prefs") |> json_response(200)

      assert body == %{"ok" => true, "prefs" => %{}}
    end

    test "a board picked is written to the guest row and read back", %{conn: conn} do
      guest_id = new_guest_id()

      body =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> post(~p"/papi/me/prefs", %{"key" => "backgammon_theme", "value" => "midnight"})
        |> json_response(200)

      assert body == %{"ok" => true, "prefs" => %{"backgammon_theme" => "midnight"}}
      assert Repo.get(Guests.Guest, guest_id).prefs == %{"backgammon_theme" => "midnight"}

      # And the same cookie reads it back on a later visit.
      assert %{"prefs" => %{"backgammon_theme" => "midnight"}} =
               build_conn() |> as_guest(guest_id) |> get(~p"/papi/me/prefs") |> json_response(200)
    end

    test "picking again replaces it and leaves other keys alone", %{conn: conn} do
      guest_id = new_guest_id()
      Guests.save_pref(guest_id, "something_else", "kept")

      conn
      |> as_guest(guest_id)
      |> with_csrf()
      |> post(~p"/papi/me/prefs", %{"key" => "backgammon_theme", "value" => "neon"})
      |> json_response(200)

      assert Repo.get(Guests.Guest, guest_id).prefs == %{
               "something_else" => "kept",
               "backgammon_theme" => "neon"
             }
    end

    test "a board that does not exist is refused and nothing is written", %{conn: conn} do
      guest_id = new_guest_id()

      body =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> post(~p"/papi/me/prefs", %{"key" => "backgammon_theme", "value" => "plaid"})
        |> json_response(422)

      assert body["error"]["code"] == "validation_failed"
      # The row exists (the page that handed out the CSRF token touched it),
      # but nothing was kept in it.
      assert Repo.get(Guests.Guest, guest_id).prefs == %{}
    end

    test "a preference the site does not keep is refused", %{conn: conn} do
      body =
        conn
        |> as_guest(new_guest_id())
        |> with_csrf()
        |> post(~p"/papi/me/prefs", %{"key" => "admin", "value" => "true"})
        |> json_response(422)

      assert body["error"]["message"] == "Unknown preference"
    end

    test "a write without the CSRF token is refused", %{conn: conn} do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> csrf_checked()
        |> post(~p"/papi/me/prefs", %{"key" => "backgammon_theme", "value" => "neon"})
      end
    end
  end

  # ---------- Guest identity ----------

  describe "guest identity" do
    test "creating a game saves the name and records the guest id on the seat", %{conn: conn} do
      guest_id = new_guest_id()

      body =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> create(%{"format" => "single", "name" => "Alice"})

      assert Repo.get(Guests.Guest, guest_id).name == "Alice"

      # The seat in the game row's players jsonb carries the guest id.
      assert [%{"name" => "Alice", "guest_id" => ^guest_id}] = game_row(body["id"]).players
    end

    test "joining a game saves the joiner's name and guest id too", %{conn: conn} do
      %{game_id: game_id} = GameFixtures.lobby("single", pid1: self())
      guest_id = new_guest_id()

      conn
      |> as_guest(guest_id)
      |> with_csrf()
      |> post(~p"/papi/games/backgammon/rooms/#{game_id}", %{"name" => "Bob"})
      |> json_response(200)

      assert Repo.get(Guests.Guest, guest_id).name == "Bob"

      # Each seat carries the guest holding it: Alice's from the fixture,
      # Bob's from the cookie this request came with.
      assert [
               %{"name" => "Alice", "guest_id" => _alice},
               %{"name" => "Bob", "guest_id" => ^guest_id}
             ] =
               game_row(game_id).players
    end

    test "mounting a page touches the guest's row", %{conn: conn} do
      guest_id = new_guest_id()
      get(as_guest(conn, guest_id), ~p"/papi/library")

      guest = Repo.get(Guests.Guest, guest_id)
      assert guest
      assert guest.name == nil

      # A later visit only moves the clock forward.
      long_ago = ~U[2020-01-01 00:00:00.000000Z]

      from(g in Guests.Guest, where: g.id == ^guest_id)
      |> Repo.update_all(set: [last_seen_at: long_ago])

      get(as_guest(build_conn(), guest_id), ~p"/papi/games/backgammon")
      assert DateTime.compare(Repo.get(Guests.Guest, guest_id).last_seen_at, long_ago) == :gt
    end

    test "the guest id survives rehydration harmlessly", %{conn: conn} do
      guest_id = new_guest_id()

      body =
        conn
        |> as_guest(guest_id)
        |> with_csrf()
        |> create(%{"format" => "single", "name" => "Alice"})

      game_id = body["id"]
      Persister.flush()

      # Stop the room the way a deploy does, then rehydrate via lookup.
      {:ok, pid} = GameSupervisor.find_game(game_id)
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(GameSupervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
      wait_unregistered(game_id)

      assert {:ok, _pid} = Game.lookup_game(game_id)

      state = Game.get_server_state(game_id)
      assert [%{guest_id: ^guest_id, name: "Alice"}] = Map.values(state.connections)

      # And it round-trips back out through the write path unchanged.
      assert [%{"guest_id" => ^guest_id}] = game_row(game_id).players
    end

    test "a guest is nobody's account until they sign in" do
      assert Repo.all(Oskol.Auth.User) == []

      guest_id = new_guest_id()
      :ok = Guests.save_name(guest_id, "Nadia")
      assert %{user_id: nil} = Repo.get(Guests.Guest, guest_id)
    end
  end

  # ---------- CSRF ----------

  describe "forgery protection" do
    test "a post with no CSRF token is refused", %{conn: conn} do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        conn
        |> csrf_checked()
        |> post(~p"/papi/games/backgammon", %{"format" => "single", "name" => "Alice"})
      end
    end

    test "a post carrying the token in x-csrf-token is let through", %{conn: conn} do
      body = conn |> with_csrf() |> create(%{"format" => "single", "name" => "Alice"})

      assert body["ok"] == true
    end
  end

  # A player process that stays alive until it is told not to: what a
  # LiveView or a channel is to a room.
  defp idle_player do
    parent = self()
    spawn(fn -> receive do: (:stop -> send(parent, :stopped)) end)
  end

  defp stop_player(game_id, pid) do
    send(pid, :stop)
    assert_receive :stopped, 1000
    wait_disconnected(game_id)
  end

  defp wait_disconnected(game_id, tries \\ 100) do
    if Game.get_server_state(game_id) |> GameServerState.disconnected_seats() == [] and tries > 0 do
      Process.sleep(10)
      wait_disconnected(game_id, tries - 1)
    end
  end

  defp wait_unregistered(game_id, tries \\ 100) do
    case GameSupervisor.find_game(game_id) do
      :error ->
        :ok

      {:ok, _} when tries > 0 ->
        Process.sleep(10)
        wait_unregistered(game_id, tries - 1)
    end
  end
end
