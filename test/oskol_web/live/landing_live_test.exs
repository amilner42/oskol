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
    assert html =~ "THE CLASSICS."
    assert has_element?(view, "#game-backgammon", "Backgammon")
    assert has_element?(view, "#game-poker", "Poker")
    assert page_title(view) =~ "Two-player games from a link"
  end

  test "games with no engine yet are shown but are not playable and not claimed", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    for {slug, name} <- [{"chess", "Chess"}, {"go", "Go"}] do
      assert has_element?(view, "##{"game-" <> slug}", name)
      # A disabled button, not a link: nothing to click and nowhere to go.
      assert has_element?(view, "##{"game-" <> slug} button[disabled]", "SOON")
      refute has_element?(view, "##{"game-" <> slug} a")
      refute has_element?(view, "a[href='/#{slug}']")
    end

    # Plain HTML is fine; a structured-data claim that they are playable is not.
    [json_ld] =
      Regex.run(~r|<script type="application/ld\+json">(.*?)</script>|s, html,
        capture: :all_but_first
      )

    parts = Jason.decode!(String.trim(json_ld))["hasPart"]
    assert parts |> Enum.map(& &1["name"]) |> Enum.sort() == ["Backgammon", "Poker"]
    refute Enum.any?(parts, &String.ends_with?(&1["url"], ["/chess", "/go"]))
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

    assert_redirect(guest, "/backgammon/#{game_id}?name=Bob")
    # The creator is told over pubsub; allow for a busy test run
    assert_redirect(host, "/backgammon/#{game_id}?name=Alice", 2000)

    state = Oskol.Game.get_server_state(game_id)
    assert state.instance != nil
    assert Oskol.GameKit.player_update(state.instance, "x")["clock"]["label"] == "3 min + 2 s"
  end

  test "a later visitor to a started game may only reconnect as a seated player", %{conn: conn} do
    {_host, game_id} = create(conn)
    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert_redirect(guest, "/backgammon/#{game_id}?name=Bob")

    # Both players' pages went to the game, so their seats show as reconnectable
    {:ok, late, html} = live(build_conn(), ~p"/backgammon?game=#{game_id}")
    assert html =~ "RECONNECT AS"
    refute has_element?(late, "form[phx-submit=submit_player_name]")
    late |> element("button[phx-value-player_name=Bob]") |> render_click()
    assert_redirect(late, "/backgammon/#{game_id}?name=Bob")
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

    assert_redirect(guest, "/poker/#{game_id}?name=Bob")
    started = Oskol.Game.get_server_state(game_id)
    update = Oskol.GameKit.player_update(started.instance, started.seat_order |> hd())
    assert update["scene"]["data"]["format"] == "sng"
    assert update["clock"]["label"] == "20 s per action + 60 s bank"
  end

  test "the play page serves the Elm client for a known game", %{conn: conn} do
    %{game_id: game_id} = Oskol.GameFixtures.started()
    conn = get(conn, ~p"/backgammon/#{game_id}?name=Alice")
    assert html_response(conn, 200) =~ "data-game-slug=\"backgammon\""
    assert html_response(conn, 200) =~ "data-player-id=\""
    assert get(build_conn(), ~p"/chess/#{game_id}") |> response(404)
  end
end
