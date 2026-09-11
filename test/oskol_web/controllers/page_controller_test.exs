defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  # `/` and `/:slug` belong to `OskolWeb.SpaController` now; their heads are
  # covered in `spa_controller_test.exs`.

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
        refute conn.resp_body =~ ~s(id="elm-app")
      end
    end

    test "a valid token serves the client", %{conn: conn} do
      %{game_id: game_id, t1: t1, t2: t2} = Oskol.GameFixtures.started()
      html = conn |> get(~p"/backgammon/#{game_id}?t=#{t1}") |> html_response(200)
      # The client reads the game id and the seat token out of the URL it was
      # served at; the page itself carries neither, and never the other seat's.
      assert html =~ ~s(id="elm-app")
      refute html =~ t2
    end

    test "the client is served exactly once", %{conn: conn} do
      # This page is a whole document and takes no layout. Two copies of the
      # bundle would boot two Elm apps in one browser, and the second one's
      # channel would take the seat off the first: the player's own reconnect
      # telling them their seat was opened somewhere else.
      %{game_id: game_id, t1: t1} = Oskol.GameFixtures.started()
      html = conn |> get(~p"/backgammon/#{game_id}?t=#{t1}") |> html_response(200)

      assert length(String.split(html, "/assets/js/app.js")) - 1 == 1
      assert length(String.split(html, ~s(id="elm-app"))) - 1 == 1
      assert length(String.split(html, "<html")) - 1 == 1
    end

    test "an unknown game slug is a 404", %{conn: conn} do
      %{game_id: game_id} = Oskol.GameFixtures.started()
      assert conn |> get("/checkers/#{game_id}") |> response(404)
    end

    test "a token from another room does not open this one", %{conn: conn} do
      %{game_id: game_id} = Oskol.GameFixtures.started()
      %{t1: other_token} = Oskol.GameFixtures.started()

      conn = get(conn, "/backgammon/#{game_id}?t=#{other_token}")
      assert redirected_to(conn) == "/backgammon?game=#{game_id}"
    end
  end
end
