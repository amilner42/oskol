defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  # `/` and `/:slug` belong to `OskolWeb.SpaController` now; their heads are
  # covered in `spa_controller_test.exs`.

  test "the sitemap lists the library and the game", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    assert response_content_type(conn, :xml) =~ "application/xml"
    body = response(conn, 200)
    assert body =~ "<loc>http://localhost:4002/</loc>"
    assert body =~ "<loc>http://localhost:4002/backgammon</loc>"
    refute body =~ "/poker"
    refute body =~ "/chess"
    refute body =~ "/go<"
    refute body =~ "game="
    # Puzzles are indexable pages, but there are too many to list.
    refute body =~ "/puzzles"
  end

  test "robots allows crawling and points at the sitemap", %{conn: conn} do
    body = conn |> get("/robots.txt") |> response(200)
    assert body =~ "Allow: /"
    assert body =~ "Sitemap: https://oskol.io/sitemap.xml"
  end

  test "a running game page is not indexed", %{conn: conn} do
    %{game_id: game_id} = Oskol.GameFixtures.started()
    html = conn |> get(~p"/backgammon/#{game_id}") |> html_response(200)
    assert html =~ ~s(<meta name="robots" content="noindex")
    assert html =~ ~s(<meta name="referrer" content="no-referrer")
    assert html =~ "<title>Backgammon · Oskol</title>"
  end

  describe "the play page carries no credential" do
    test "the plain room URL serves the client", %{conn: conn} do
      # There is nothing in the URL to gate on any more: the shell is served
      # to whoever asks, and what the room will show this browser is the
      # room's answer on the game channel, against its guest cookie.
      %{game_id: game_id, g1: g1, g2: g2} = Oskol.GameFixtures.started()
      html = conn |> get(~p"/backgammon/#{game_id}") |> html_response(200)
      assert html =~ ~s(id="elm-app")
      # No seat's identity is written into the page, either one's.
      refute html =~ g1
      refute html =~ g2
    end

    test "a link minted before seat tokens were dropped still works", %{conn: conn} do
      # Live rooms are out there whose players' links carry a `?t=`. The
      # token means nothing now, and must cost nothing: the page is served
      # as if it were not there, and the browser's own cookie seats it.
      %{game_id: game_id} = Oskol.GameFixtures.started()

      for query <- ["?t=", "?t=an-old-token", "?name=Alice", ""] do
        html = conn |> get("/backgammon/#{game_id}#{query}") |> html_response(200)
        assert html =~ ~s(id="elm-app")
      end
    end

    test "the client is served exactly once", %{conn: conn} do
      # This page is a whole document and takes no layout. Two copies of the
      # bundle would boot two Elm apps in one browser, and the second one's
      # channel would take the seat off the first: the player's own reconnect
      # telling them their seat was opened somewhere else.
      %{game_id: game_id} = Oskol.GameFixtures.started()
      html = conn |> get(~p"/backgammon/#{game_id}") |> html_response(200)

      assert length(String.split(html, "/assets/js/app.js")) - 1 == 1
      assert length(String.split(html, ~s(id="elm-app"))) - 1 == 1
      assert length(String.split(html, "<html")) - 1 == 1
    end

    test "an unknown game slug is a 404", %{conn: conn} do
      %{game_id: game_id} = Oskol.GameFixtures.started()
      assert conn |> get("/checkers/#{game_id}") |> response(404)
    end
  end
end
