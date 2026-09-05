defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  test "GET / renders the game library with its title and description", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "PLAY THE CLASSICS."
    assert html =~ "Backgammon"
    assert html =~ "Poker"
    assert html =~ ~s(>Two-player games from a link · Oskol</title>)
    assert html =~ ~s(<meta name="description" content="Free two-player games)
    assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/")
    assert html =~ ~s("@type":"WebSite")
  end

  test "a game page carries its own title, description, canonical link and structured data",
       %{conn: conn} do
    html = conn |> get(~p"/poker") |> html_response(200)
    # The whole title, not just the suffix: crawlers must see a real one.
    assert html =~ ~s(>Play heads-up poker online with a friend · Oskol</title>)
    refute html =~ ~s(> · Oskol</title>)
    assert html =~ ~s(<meta name="description" content="Heads-up no-limit Texas hold)
    assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/poker")

    assert html =~
             ~s(<meta property="og:title" content="Play heads-up poker online with a friend")

    assert html =~ ~s("@type":"VideoGame")
    assert html =~ "<h1"
    assert html =~ "POKER IN BRIEF"
    assert html =~ "QUESTIONS"
    # An invite link is the same page and must not compete with it
    assert conn |> get(~p"/poker?game=abc123") |> html_response(200) =~
             ~s(<link rel="canonical" href="http://localhost:4002/poker")
  end

  test "the sitemap lists the library and every game", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    assert response_content_type(conn, :xml) =~ "application/xml"
    body = response(conn, 200)
    assert body =~ "<loc>http://localhost:4002/</loc>"
    assert body =~ "<loc>http://localhost:4002/poker</loc>"
    assert body =~ "<loc>http://localhost:4002/backgammon</loc>"
    assert body =~ "<loc>http://localhost:4002/go</loc>"
    assert body =~ "<loc>http://localhost:4002/chess</loc>"
    refute body =~ "game="
  end

  test "robots allows crawling and points at the sitemap", %{conn: conn} do
    body = conn |> get("/robots.txt") |> response(200)
    assert body =~ "Allow: /"
    assert body =~ "Sitemap: https://oskol.io/sitemap.xml"
  end

  test "a running game page is not indexed", %{conn: conn} do
    %{game_id: game_id, t1: t1} = Oskol.GameFixtures.started()
    html = conn |> get(~p"/backgammon/#{game_id}?t=#{t1}") |> html_response(200)
    assert html =~ ~s(<meta name="robots" content="noindex")
    assert html =~ ~s(<meta name="referrer" content="no-referrer")
    assert html =~ "<title>Backgammon · Oskol</title>"
  end

  describe "the play page is seat-token only" do
    test "a name in the URL grants nothing", %{conn: conn} do
      %{game_id: game_id} = Oskol.GameFixtures.started()

      for query <- ["?name=Alice", "", "?t=", "?t=not-a-token"] do
        conn = get(conn, "/backgammon/#{game_id}#{query}")
        assert redirected_to(conn) == "/backgammon?game=#{game_id}"
        refute conn.resp_body =~ "elm-game-app"
      end
    end

    test "a valid token serves the client with that seat and its token", %{conn: conn} do
      %{game_id: game_id, p1: p1, t1: t1, t2: t2} = Oskol.GameFixtures.started()
      html = conn |> get(~p"/backgammon/#{game_id}?t=#{t1}") |> html_response(200)
      assert html =~ ~s(data-player-id="#{p1}")
      assert html =~ ~s(data-seat-token="#{t1}")
      # A page served to one player never carries the other's token.
      refute html =~ t2
    end

    test "a token from another room does not open this one", %{conn: conn} do
      %{game_id: game_id} = Oskol.GameFixtures.started()
      %{t1: other_token} = Oskol.GameFixtures.started()

      conn = get(conn, "/backgammon/#{game_id}?t=#{other_token}")
      assert redirected_to(conn) == "/backgammon?game=#{game_id}"
    end
  end
end
