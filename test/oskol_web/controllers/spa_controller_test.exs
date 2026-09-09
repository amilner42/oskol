defmodule OskolWeb.SpaControllerTest do
  @moduledoc """
  `/` and `/:slug` are served by the Elm app, so what is left for the server
  to be tested on is what a crawler and a first paint need: the shell, the
  document head (title, description, canonical, Open Graph, JSON-LD), a real
  404 for an unknown slug, the CSRF token the client sends back, and the
  guest identity that rides in with the page.

  Everything the visitor can click — the forms, the format pickers, the
  lobby — is the client's now, and is covered by elm-test and Playwright.
  """
  use OskolWeb.ConnCase, async: true

  import Ecto.Query

  alias Oskol.GameKit
  alias OskolWeb.GameCopy

  @guest_cookie "_oskol_guest"

  # The head is rendered by HEEx, so anything with an apostrophe in it
  # (poker's "hold'em") arrives escaped.
  defp esc(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp json_ld(html) do
    [script] =
      Regex.run(~r|<script type="application/ld\+json">(.*?)</script>|s, html,
        capture: :all_but_first
      )

    Jason.decode!(String.trim(script))
  end

  defp new_guest_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  describe "GET /" do
    test "serves the Elm shell", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(id="elm-app")
    end

    test "carries the site's title, description and canonical URL", %{conn: conn} do
      site = GameCopy.site()
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(>#{esc(site.title)} · Oskol</title>)
      assert html =~ ~s(<meta name="description" content="#{esc(site.description)}")
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/")
      assert html =~ ~s(<meta property="og:url" content="http://localhost:4002/")
      assert html =~ ~s(<meta property="og:title" content="#{esc(site.title)}")
    end

    test "the structured data lists every registered game", %{conn: conn} do
      data = conn |> get(~p"/") |> html_response(200) |> json_ld()

      assert data["@type"] == "WebSite"
      assert data["url"] == "http://localhost:4002/"
      assert data["description"] == GameCopy.site().description

      games = GameKit.games()
      assert games != []

      assert data["hasPart"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
               games |> Enum.map(& &1["name"]) |> Enum.sort()

      for game <- games do
        part = Enum.find(data["hasPart"], &(&1["name"] == game["name"]))
        assert part["@type"] == "VideoGame"
        assert part["url"] == "http://localhost:4002/#{game["slug"]}"
      end
    end

    test "the CSRF token is on the page for the Elm client to send back", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert [token] =
               Regex.run(~r|<meta name="csrf-token" content="([^"]+)"|, html,
                 capture: :all_but_first
               )

      assert token != ""
    end
  end

  describe "GET /:slug" do
    test "every registered game gets its own head", %{conn: conn} do
      for game <- GameKit.games() do
        slug = game["slug"]
        copy = GameCopy.for_game(game)
        html = conn |> get(~p"/#{slug}") |> html_response(200)

        assert html =~ ~s(id="elm-app")
        # The whole title, not just the suffix: crawlers must see a real one.
        assert html =~ ~s(>#{esc(copy.title)} · Oskol</title>)
        refute html =~ ~s(> · Oskol</title>)
        assert html =~ ~s(<meta name="description" content="#{esc(copy.description)}")
        assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/#{slug}")
        assert html =~ ~s(<meta property="og:title" content="#{esc(copy.title)}")
        assert html =~ ~s(<meta property="og:description" content="#{esc(copy.description)}")
      end
    end

    test "a game page's structured data claims that one game", %{conn: conn} do
      for game <- GameKit.games() do
        slug = game["slug"]
        data = conn |> get(~p"/#{slug}") |> html_response(200) |> json_ld()

        assert data["@type"] == "VideoGame"
        assert data["name"] == game["name"]
        assert data["url"] == "http://localhost:4002/#{slug}"
        assert data["description"] == GameCopy.for_game(game).description
        assert data["numberOfPlayers"] == 2
        assert data["isAccessibleForFree"] == true
      end
    end

    test "an invite link is the same page and does not compete with it", %{conn: conn} do
      html = conn |> get(~p"/poker?game=abc123") |> html_response(200)
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/poker")
    end

    test "an unknown game is a 404, not a redirect to the library", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/nope") end
    end
  end

  describe "guest identity" do
    setup do
      # Every write below happens in this process (a controller request runs
      # in the test process), so a plain checkout is enough and stays async.
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Oskol.Repo)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      :ok
    end

    test "a visit mints the guest cookie and mirrors it into the session", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert %{value: id, http_only: true} = conn.resp_cookies[@guest_cookie]
      assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
      assert get_session(conn, :guest_id) == id
    end

    test "a visit upserts the guest's row and touches last_seen_at", %{conn: conn} do
      guest_id = new_guest_id()
      conn |> put_req_cookie(@guest_cookie, guest_id) |> get(~p"/") |> html_response(200)

      assert %{name: nil, last_seen_at: seen} = Oskol.Repo.get(Oskol.Guests.Guest, guest_id)
      assert seen

      long_ago = ~U[2020-01-01 00:00:00.000000Z]

      Oskol.Repo.update_all(
        from(g in Oskol.Guests.Guest, where: g.id == ^guest_id),
        set: [last_seen_at: long_ago]
      )

      build_conn() |> put_req_cookie(@guest_cookie, guest_id) |> get(~p"/backgammon")

      assert DateTime.compare(
               Oskol.Repo.get(Oskol.Guests.Guest, guest_id).last_seen_at,
               long_ago
             ) == :gt
    end

    test "a guest with a saved name gets it in a meta tag", %{conn: _conn} do
      guest_id = new_guest_id()
      :ok = Oskol.Guests.save_name(guest_id, "Renée")

      for path <- [~p"/", ~p"/backgammon"] do
        html =
          build_conn()
          |> put_req_cookie(@guest_cookie, guest_id)
          |> get(path)
          |> html_response(200)

        assert html =~ ~s(<meta name="guest-name" content="Renée">)
      end
    end

    test "a guest with no saved name gets no meta tag at all", %{conn: conn} do
      html =
        conn
        |> put_req_cookie(@guest_cookie, new_guest_id())
        |> get(~p"/")
        |> html_response(200)

      refute html =~ "guest-name"
    end
  end
end
