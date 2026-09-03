defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  test "GET / renders the game library with its title and description", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "SELECT YOUR GAME"
    assert html =~ "Backgammon"
    assert html =~ "Poker"
    assert html =~ ~r|<title[^>]*>\s*Two-player games from a link\s*· Oskol</title>|
    assert html =~ ~s(<meta name="description" content="Free two-player games)
    assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/")
    assert html =~ ~s("@type":"WebSite")
  end

  test "a game page carries its own title, description, canonical link and structured data",
       %{conn: conn} do
    html = conn |> get(~p"/poker") |> html_response(200)
    assert html =~ ~r|<title[^>]*>\s*Play heads-up poker online with a friend\s*· Oskol</title>|
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
    refute body =~ "game="
  end

  test "robots allows crawling and points at the sitemap", %{conn: conn} do
    body = conn |> get("/robots.txt") |> response(200)
    assert body =~ "Allow: /"
    assert body =~ "Sitemap: https://oskol.io/sitemap.xml"
  end

  test "a running game page is not indexed", %{conn: conn} do
    %{game_id: game_id} = Oskol.GameFixtures.started()
    html = conn |> get(~p"/backgammon/#{game_id}?name=Alice") |> html_response(200)
    assert html =~ ~s(<meta name="robots" content="noindex")
    assert html =~ "<title>Backgammon · Oskol</title>"
  end
end
