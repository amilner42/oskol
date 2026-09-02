defmodule OskolWeb.LandingLiveTest do
  use OskolWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the library lists every registered game", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Games for two"
    assert has_element?(view, "#game-tilt", "Tilt")
    assert html =~ "Head-to-head poker roguelike"
  end

  test "a game page offers a new game and links back to the library", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/tilt")
    assert html =~ "Tilt"
    assert has_element?(view, "form[phx-submit=new_game]")
    assert has_element?(view, "a[href='/']", "All games")
  end

  test "picking a game from the library is a patch, not a page load", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#game-backgammon") |> render_click()
    assert_patch(view, "/backgammon")
    assert has_element?(view, "#game-title", "Backgammon")
    assert has_element?(view, "form[phx-submit=new_game]")
    view |> element("header a[href='/']", "All games") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#game-tilt")
  end

  test "an unknown game redirects to the library", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/nope")
  end

  test "creating a game enters the lobby with the game's formats", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tilt")

    html =
      view
      |> form("form[phx-submit=new_game]", %{"player_name" => "Alice"})
      |> render_submit()

    assert html =~ "Waiting for your opponent"
    assert has_element?(view, "#format-short", "Short")
    assert has_element?(view, "#format-standard", "Standard")
    assert has_element?(view, "#format-extended", "Extended")
    assert_patch(view)
    assert view |> element("#share-link") |> render() =~ "/tilt?game="
  end

  test "two players can agree on a format and start", %{conn: conn} do
    {:ok, host, _} = live(conn, ~p"/tilt")
    host |> form("form[phx-submit=new_game]", %{"player_name" => "Alice"}) |> render_submit()
    path = assert_patch(host)
    %{"game" => game_id} = URI.decode_query(URI.parse(path).query)

    {:ok, guest, _} = live(build_conn(), ~p"/tilt?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    host |> element("#format-short") |> render_click()
    guest |> element("#format-short") |> render_click()

    assert render(host) =~ "Both picked Short"
    host |> element("button", "Start Game") |> render_click()
    assert_redirect(host, "/tilt/#{game_id}?name=Alice")
    assert Oskol.Game.get_server_state(game_id).instance != nil
  end

  test "the play page serves the Elm client for a known game", %{conn: conn} do
    %{game_id: game_id} = Oskol.GameFixtures.started()
    conn = get(conn, ~p"/tilt/#{game_id}?name=Alice")
    assert html_response(conn, 200) =~ "data-game-slug=\"tilt\""
    assert html_response(conn, 200) =~ "data-player-id=\""
    assert get(build_conn(), ~p"/chess/#{game_id}") |> response(404)
  end
end

defmodule OskolWeb.LandingLiveClockTest do
  use OskolWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the lobby offers time controls and needs agreement", %{conn: conn} do
    {:ok, host, _} = live(conn, ~p"/backgammon")
    host |> form("form[phx-submit=new_game]", %{"player_name" => "Alice"}) |> render_submit()
    path = assert_patch(host)
    %{"game" => game_id} = URI.decode_query(URI.parse(path).query)

    {:ok, guest, _} = live(build_conn(), ~p"/backgammon?game=#{game_id}")

    guest
    |> form("form[phx-submit=submit_player_name]", %{"player_name" => "Bob"})
    |> render_submit()

    assert has_element?(host, "#clock-none")
    assert has_element?(host, "#clock-blitz", "Blitz")
    host |> element("#format-single") |> render_click()
    guest |> element("#format-single") |> render_click()
    host |> element("#clock-blitz") |> render_click()
    assert render(host) =~ "Agree on a time control"
    guest |> element("#clock-blitz") |> render_click()
    assert render(host) =~ "Both picked Single game"
    host |> element("button", "Start Game") |> render_click()
    assert_redirect(host, "/backgammon/#{game_id}?name=Alice")
    state = Oskol.Game.get_server_state(game_id)
    assert Oskol.GameKit.player_update(state.instance, "x")["clock"]["label"] == "3 min + 2 s"
  end
end
