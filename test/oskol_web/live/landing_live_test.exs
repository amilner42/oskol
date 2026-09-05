defmodule OskolWeb.LandingLiveTest do
  use OskolWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # The creator picks everything and submits their name.
  defp create(conn, opts \\ []) do
    {:ok, host, _} = live(conn, ~p"/backgammon")
    if f = opts[:format], do: host |> element("#format-#{f}") |> render_click()
    if c = opts[:clock], do: host |> element("#clock-#{c}") |> render_click()
    host |> form("form[phx-submit=new_game]", %{"player_name" => "Alice"}) |> render_submit()
    path = assert_patch(host)
    %{"game" => game_id} = URI.decode_query(URI.parse(path).query)
    {host, game_id}
  end

  test "the library lists every registered game", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "PLAY THE CLASSICS."
    assert has_element?(view, "#game-backgammon", "Backgammon")
    assert has_element?(view, "#game-poker", "Poker")
    assert has_element?(view, "#game-go", "Go")
    assert has_element?(view, "#game-chess", "Chess")
    assert page_title(view) =~ "Two-player games from a link"
  end

  test "the library cards lead with art: every game's frames, and no subtext", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    for slug <- ~w(poker backgammon chess go) do
      frames = OskolWeb.GameArt.frame_count(slug)
      assert frames > 1, "#{slug} needs frames to animate"
      card = view |> element("#game-#{slug}") |> render()
      # One <svg> per frame, stacked into the reel the CSS animation steps through.
      assert length(String.split(card, "<svg")) == frames + 1
      assert card =~ "game-art-anim"
    end

    # The card is just the marquee and the art; the whole card is the link.
    refute html =~ "Heads-up no-limit hold"
    refute html =~ "Sit down at a cash table"
    assert has_element?(view, "a#game-poker")
  end

  test "each card's accent colour appears inside its own art", %{conn: conn} do
    # Marquee and animation have to read as one designed object, so the
    # accent is the felt border, the points, the dark pieces, the board wood.
    {:ok, view, _} = live(conn, ~p"/")

    for slug <- ~w(poker backgammon chess go) do
      accent = OskolWeb.GameArt.accent(slug)
      card = view |> element("#game-#{slug}") |> render()
      assert card =~ ~s(fill="#{accent}"), "#{slug} art never uses its accent #{accent}"
    end
  end

  test "a game page's art is still, so it never competes with the form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/poker")
    hero = view |> element("#game-hero-poker") |> render()
    assert length(String.split(hero, "<svg")) == 2
    refute hero =~ "game-art-anim"
  end

  test "games with no engine yet are shown but are not playable and not claimed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # Every catalog game has an engine now: no SOON placeholders remain.
    refute html =~ "SOON"

    for slug <- ~w(go chess) do
      assert has_element?(view, "a#game-#{slug}")
      refute has_element?(view, "#game-#{slug}", "SOON")
    end

    # Plain HTML is fine; a structured-data claim that they are playable is not.
    [json_ld] =
      Regex.run(~r|<script type="application/ld\+json">(.*?)</script>|s, html,
        capture: :all_but_first
      )

    parts = Jason.decode!(String.trim(json_ld))["hasPart"]
    assert parts |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ["Backgammon", "Chess", "Go", "Poker"]

    assert Enum.any?(parts, &String.ends_with?(&1["url"], "/go"))
    assert Enum.any?(parts, &String.ends_with?(&1["url"], "/chess"))
  end

  test "moving between the library and a game keeps the titles right", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#game-poker") |> render_click()
    assert_patch(view, "/poker")
    assert page_title(view) =~ "Play heads-up poker online"
    view |> element("#other-games a[href='/backgammon']") |> render_click()
    assert_patch(view, "/backgammon")
    assert page_title(view) =~ "Play backgammon online"
    assert has_element?(view, "#format-single.tile-mine")
    view |> element("header a[href='/']", "ALL GAMES") |> render_click()
    assert_patch(view, "/")
    assert page_title(view) =~ "Two-player games from a link"
  end

  test "a game page lets the creator pick a mode and a clock, and links back", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/backgammon")
    assert html =~ "Backgammon"
    assert page_title(view) =~ "Play backgammon online with a friend"
    assert has_element?(view, "h1", "Play backgammon online with a friend")
    # Backgammon offers no twist yet, so the form does not show an empty section
    refute has_element?(view, "#twist")
    assert has_element?(view, "#rules h2", "BACKGAMMON IN BRIEF")
    assert has_element?(view, "#other-games a[href='/poker']", "Poker")
    assert has_element?(view, "#modes h2", "MODES")
    assert has_element?(view, "#faq h2", "QUESTIONS")
    assert has_element?(view, "form[phx-submit=new_game]")
    assert has_element?(view, "#format-single.tile-mine")
    assert has_element?(view, "#format-match5", "Match to 5")
    assert has_element?(view, "#clock-none.tile-mine")
    assert has_element?(view, "#clock-blitz", "Blitz")
    assert has_element?(view, "a[href='/']", "ALL GAMES")

    view |> element("#format-match3") |> render_click()
    assert has_element?(view, "#format-match3.tile-mine")
    refute has_element?(view, "#format-single.tile-mine")
  end

  test "picking a game from the library is a patch, not a page load", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#game-backgammon") |> render_click()
    assert_patch(view, "/backgammon")
    assert has_element?(view, "#game-title", "Backgammon")
    assert has_element?(view, "form[phx-submit=new_game]")
    view |> element("header a[href='/']", "ALL GAMES") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#game-backgammon")
  end

  test "an unknown game is a 404", %{conn: conn} do
    assert_error_sent 404, fn -> get(conn, ~p"/nope") end
  end

  test "an invite to a room that is gone does not create one", %{conn: conn} do
    {:ok, guest, _} = live(conn, ~p"/backgammon?game=gone-room")

    html =
      guest
      |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
      |> render_submit()

    assert html =~ "That game is over"
    assert has_element?(guest, "form[phx-submit=new_game]")
    assert :not_found = Oskol.Game.lookup_game("gone-room")
  end

  test "names are bounded", %{conn: conn} do
    {:ok, host, _} = live(conn, ~p"/backgammon")

    html =
      host
      |> form("form[phx-submit=new_game]", %{"player_name" => String.duplicate("a", 25)})
      |> render_submit()

    assert html =~ "24 characters at most"
  end

  test "creating a game shows the share link and waits for the opponent", %{conn: conn} do
    {host, game_id} = create(conn, format: "match5", clock: "blitz")
    html = render(host)
    assert html =~ "Waiting for your opponent"
    assert host |> element("#share-link") |> render() =~ "/backgammon?game=#{game_id}"
    assert host |> element("#setup-summary") |> render() =~ "Match to 5 · Blitz clock"
    state = Oskol.Game.get_server_state(game_id)
    assert state.setup.format == "match5"
    assert state.setup.clock == "blitz"
    assert state.instance == nil
  end

  test "the opponent opens the link, types a name, and both are in the game", %{conn: conn} do
    {host, game_id} = create(conn, format: "match3", clock: "blitz")

    {:ok, guest, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}")
    assert html =~ "Alice"
    assert html =~ "challenged you"
    assert guest |> element("#setup-summary") |> render() =~ "Match to 3 · Blitz clock"

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    # Each player is sent to the table with their own seat token, never a name.
    state = Oskol.Game.get_server_state(game_id)
    [p1, p2] = state.seat_order
    t1 = Oskol.Game.GameServerState.token_for(state, p1)
    t2 = Oskol.Game.GameServerState.token_for(state, p2)

    assert_redirect(guest, "/backgammon/#{game_id}?t=#{t2}")
    # The creator is told over pubsub; allow for a busy test run
    assert_redirect(host, "/backgammon/#{game_id}?t=#{t1}", 2000)

    state = Oskol.Game.get_server_state(game_id)
    assert state.instance != nil
    assert Oskol.GameKit.player_update(state.instance, "x")["clock"]["label"] == "3 min + 2 s"
  end

  test "a later visitor to a started game chooses which empty seat to take", %{conn: conn} do
    {_host, game_id} = create(conn)
    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest)

    # Both LiveViews navigated away, so both seats read as away: the invite
    # link asks who this is, and picking a seat rotates its token.
    state = Oskol.Game.get_server_state(game_id)
    [p1, p2] = state.seat_order
    old_token = Oskol.Game.GameServerState.token_for(state, p2)

    {:ok, late, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}")
    assert html =~ "WHO ARE YOU?"
    assert html =~ "Alice"
    assert html =~ "Bob"
    refute has_element?(late, "form[phx-submit=submit_player_name]")
    # The chooser offers seats by id; it never puts a token on the page.
    refute html =~ old_token

    late |> element("#reclaim-#{p2}") |> render_click()
    new_token = Oskol.GameFixtures.token_for(game_id, p2)
    refute new_token == old_token
    assert_redirect(late, "/backgammon/#{game_id}?t=#{new_token}")
    assert Oskol.Game.get_server_state(game_id).connections[p2].name == "Bob"
    refute p1 == p2
  end

  test "one seat away: the invite offers that seat back by name", %{conn: conn} do
    {host, game_id} = create(conn)
    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest)
    assert_redirect(host, 2000)

    # Put Alice back at the table with her token, leaving only Bob away.
    state = Oskol.Game.get_server_state(game_id)
    [p1, p2] = state.seat_order
    t1 = Oskol.Game.GameServerState.token_for(state, p1)
    {:ok, ^p1, _} = Oskol.Game.attach(game_id, t1, self())

    {:ok, _late, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}")
    assert html =~ "CONTINUE?"
    assert html =~ "Rejoin as"
    assert html =~ "Bob"
    # Alice is connected: her seat is not on offer.
    refute html =~ "reclaim-#{p1}"
    assert html =~ "reclaim-#{p2}"
  end

  # The security bar: a stranger on the invite link of a full, live table
  # gets no seat, no token and no game state at all.
  test "both players connected: the invite link is a dead end", %{conn: conn} do
    {host, game_id} = create(conn)
    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest)
    assert_redirect(host, 2000)

    state = Oskol.Game.get_server_state(game_id)
    [p1, p2] = state.seat_order
    t1 = Oskol.Game.GameServerState.token_for(state, p1)
    t2 = Oskol.Game.GameServerState.token_for(state, p2)
    {:ok, ^p1, _} = Oskol.Game.attach(game_id, t1, self())
    {:ok, ^p2, _} = Oskol.Game.attach(game_id, t2, spawn(fn -> Process.sleep(30_000) end))

    {:ok, stranger, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}")
    assert html =~ "TABLE FULL"
    refute html =~ t1
    refute html =~ t2
    refute has_element?(stranger, "form[phx-submit=submit_player_name]")
    refute has_element?(stranger, "button[phx-click=reclaim_seat]")

    # And a made-up token is not a way in either.
    {:ok, _forger, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}&t=nonsense")
    assert html =~ "TABLE FULL"

    assert Enum.all?(Oskol.Game.get_server_state(game_id).connections, fn {_, c} ->
             c.connected
           end)
  end

  test "a seat token brings a player straight back to their game", %{conn: conn} do
    {_host, game_id} = create(conn)
    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest)

    state = Oskol.Game.get_server_state(game_id)
    [_p1, p2] = state.seat_order
    t2 = Oskol.Game.GameServerState.token_for(state, p2)

    # Straight through to the table, and the token is unchanged: only the
    # invite-link route rotates it.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(build_conn(), ~p"/backgammon?game=#{game_id}&t=#{t2}")

    assert to == "/backgammon/#{game_id}?t=#{t2}"
    # The seat is still Bob's: attaching from the lobby did not disturb it.
    assert Oskol.Game.get_server_state(game_id).connections[p2].name == "Bob"
  end

  test "a format's settings are offered as chips and land in the room's setup", %{conn: conn} do
    {:ok, host, _} = live(conn, ~p"/poker")
    # Cash is the first format: its stakes and top-up settings show, with defaults picked
    assert has_element?(host, "#choice-stake-1-2.tile-mine")
    assert has_element?(host, "#choice-top_up-yes.tile-mine")
    assert has_element?(host, "#clock-poker.tile-mine")
    host |> element("#choice-stake-5-10") |> render_click()
    host |> element("#choice-top_up-no") |> render_click()
    assert has_element?(host, "#choice-stake-5-10.tile-mine")

    # Switching format swaps the settings and resets the choices
    host |> element("#format-sng") |> render_click()
    assert has_element?(host, "#choice-speed-regular.tile-mine")
    refute has_element?(host, "#choice-stake-5-10")
    host |> element("#choice-speed-turbo") |> render_click()

    host |> form("form[phx-submit=new_game]", %{"player_name" => "Alice"}) |> render_submit()
    path = assert_patch(host)
    %{"game" => game_id} = URI.decode_query(URI.parse(path).query)
    state = Oskol.Game.get_server_state(game_id)
    assert state.setup.format == "sng"
    assert state.setup.selections == %{"speed" => "turbo"}
    assert state.setup.clock == "poker"

    assert host |> element("#setup-summary") |> render() =~
             "Sit &amp; go · Turbo · Standard clock"

    {:ok, guest, _} = live(build_conn(), ~p"/poker?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest)
    started = Oskol.Game.get_server_state(game_id)
    update = Oskol.GameKit.player_update(started.instance, started.seat_order |> hd())
    assert update["scene"]["data"]["format"] == "sng"
    assert update["clock"]["label"] == "20 s per action + 60 s bank"
  end

  test "the play page serves the Elm client for a known game", %{conn: conn} do
    %{game_id: game_id, t1: t1} = Oskol.GameFixtures.started()
    conn = get(conn, ~p"/backgammon/#{game_id}?t=#{t1}")
    assert html_response(conn, 200) =~ "data-game-slug=\"backgammon\""
    assert html_response(conn, 200) =~ "data-player-id=\""
    assert get(build_conn(), ~p"/go/#{game_id}") |> response(404)
  end
end
