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
  # arrives escaped.
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

    test "the home page is the dark board: its frame is painted before the app boots",
         %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~r|<div[^>]*id="elm-app"[^>]*style="background: #1d2230"|s
      refute html =~ ~r|<div[^>]*id="elm-app"[^>]*class="paper|s

      # An invite is the paper page, as before.
      invite = build_conn() |> get(~p"/backgammon?game=abc123") |> html_response(200)
      assert invite =~ ~r|<div[^>]*id="elm-app"[^>]*class="paper min-h-screen-safe"|s
      refute invite =~ "#1d2230"
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
      html = conn |> get(~p"/backgammon?game=abc123") |> html_response(200)
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/backgammon")
    end

    test "an unknown game is a 404, not a redirect to the library", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/nope") end
    end

    test "a replay is the Elm shell for anyone with the link, seat or not", %{conn: conn} do
      html = conn |> get(~p"/backgammon/123456/replay") |> html_response(200)
      assert html =~ ~s(id="elm-app")
      assert html =~ ~s(>Replay · )
      # A room is nobody's business to index, but anyone with the link reads it.
      assert html =~ ~s(<meta name="robots" content="noindex")
    end

    test "a replay of a game Oskol does not host is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/nope/123456/replay") end
    end

    test "the games Oskol no longer hosts send their old links home", %{conn: conn} do
      for path <- [
            "/poker",
            "/poker?game=123456",
            "/poker/123456?t=secret",
            "/go",
            "/go?game=123456",
            "/go/123456",
            "/chess",
            "/chess?game=123456&t=secret",
            "/chess/123456?t=secret"
          ] do
        conn = get(conn, path)
        assert redirected_to(conn, 302) == "/", path
      end
    end
  end

  describe "GET /puzzles/:id" do
    # Everything here runs in the test process (the request is dispatched
    # in it), so the owner is this process's alone: a *shared* owner in an
    # async module would lend its connection to every other module running
    # beside it and pull it from under them when the test ends.
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Oskol.Repo, shared: false)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      :ok
    end

    # A stored puzzle, exactly as extraction would have written it, under an
    # id no other test uses: the table is global.
    defp a_puzzle(name) do
      {:stored, _id, kind, question, answer} = :oskol@puzzles@fixture.stored_sample(name)
      id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

      Oskol.Repo.insert!(%Oskol.Puzzles.Puzzle{
        id: id,
        key: "spa-" <> id,
        kind: kind,
        question: Jason.decode!(question),
        answer: Jason.decode!(answer),
        evaluated_by: %{}
      })

      id
    end

    test "a puzzle's head is its question, with the score and cube beneath", %{conn: conn} do
      id = a_puzzle("move")
      html = conn |> get(~p"/puzzles/#{id}") |> html_response(200)
      assert html =~ ~s(id="elm-app")
      prompt = esc("White to play 6-4. What's your play?")
      assert html =~ ~s(>#{prompt} · Oskol</title>)
      assert html =~ ~s(<meta property="og:title" content="#{prompt}")
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/puzzles/#{id}")

      assert html =~
               ~s(<meta name="description" content="Match play, 3 away against 5. Cube centred.)

      # The board as the picture, so a pasted link unfurls with it.
      assert html =~
               ~s(<meta property="og:image" content="http://localhost:4002/puzzles/#{id}.png">)

      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image">)
      # Open to search: a puzzle is a public page, unlike a room's replay.
      refute html =~ ~s(name="robots")
      # And nothing of where it came from.
      refute html =~ "Alice"
      refute html =~ "replay"
    end

    test "a take is asked from the responder's side: the cube is the other player's", %{
      conn: conn
    } do
      id = a_puzzle("take")
      html = conn |> get(~p"/puzzles/#{id}") |> html_response(200)
      assert html =~ ~s(>White is doubled. Take? · Oskol</title>)
      # Stored as the doubler's (White's, at 2); shown to the one doubled,
      # whose opponent holds it, with the away scores swapped.
      assert html =~ ~s(content="Match play, 5 away against 3. Cube at 2, Black&#39;s.)
    end

    # A story link: a finished game with a source for the puzzle, and the
    # share row the seat that made the mistake minted.
    defp a_story(puzzle_id) do
      game_id = "spa-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      now = DateTime.utc_now()

      Oskol.Repo.insert!(%Oskol.Persistence.Game{
        id: game_id,
        slug: "backgammon",
        config: %{"format" => "single"},
        seed: 3,
        players: [
          %{"id" => "p1", "name" => "Arie", "guest_id" => "g-arie"},
          %{"id" => "p2", "name" => "Charlie", "guest_id" => "g-charlie"}
        ],
        status: "finished",
        winners: ["p2"]
      })

      source =
        Oskol.Repo.insert!(%Oskol.Puzzles.Source{
          puzzle_id: puzzle_id,
          game_id: game_id,
          game_number: 1,
          turn: 4,
          kind: "move",
          seat: 0,
          player_id: "p1",
          played: "24/23 13/11",
          equity_lost: 0.11,
          grade: "bad"
        })

      token =
        "TOKEN" <>
          (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :upper) |> String.slice(0, 7))

      Oskol.Repo.insert!(%Oskol.Puzzles.Share{
        token: token,
        puzzle_id: puzzle_id,
        source_id: source.id,
        shared_by: "g-arie",
        shared_name: "Arie",
        inserted_at: now
      })

      token
    end

    test "a story link's head names the sharer, and the canonical stays the clean page", %{
      conn: conn
    } do
      id = a_puzzle("move")
      token = a_story(id)
      html = conn |> get(~p"/puzzles/#{id}?s=#{token}") |> html_response(200)
      headline = esc("Arie got this wrong. What's your play?")
      assert html =~ ~s(>#{headline} · Oskol</title>)
      assert html =~ ~s(<meta property="og:title" content="#{headline}")
      assert html =~ ~s(<meta name="twitter:title" content="#{headline}")
      # The description, the picture and the canonical are the plain page's.
      assert html =~ ~s(<meta name="description" content="Match play, 3 away against 5.)
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/puzzles/#{id}")
      assert html =~ ~s(<meta property="og:url" content="http://localhost:4002/puzzles/#{id}")

      assert html =~
               ~s(<meta property="og:image" content="http://localhost:4002/puzzles/#{id}.png")

      # The opponent is nowhere, and neither is the move: the story waits
      # for the reader's own attempt.
      refute html =~ "Charlie"
      refute html =~ "24/23"
    end

    test "a token nobody minted, or minted for another puzzle, leaves the head as it was", %{
      conn: conn
    } do
      id = a_puzzle("move")
      other = a_puzzle("double")
      token = a_story(other)
      prompt = esc("White to play 6-4. What's your play?")

      for path <- [
            ~p"/puzzles/#{id}?s=NOSUCHTOKEN0",
            ~p"/puzzles/#{id}?s=#{token}",
            ~p"/puzzles/#{id}?s="
          ] do
        html = conn |> get(path) |> html_response(200)
        assert html =~ ~s(<meta property="og:title" content="#{prompt}"), path
        refute html =~ "got this wrong", path
        refute html =~ "Arie", path
      end
    end

    test "a puzzle nobody stored is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/puzzles/nope0000") end
    end

    test "the practice home is its own page, with a head that says the same to everyone", %{
      conn: conn
    } do
      html = conn |> get(~p"/puzzles") |> html_response(200)
      assert html =~ ~s(id="elm-app")
      assert html =~ ~s(>Puzzles · Oskol</title>)
      assert html =~ ~s(<meta property="og:title" content="Puzzles")
      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/puzzles")
      assert html =~ ~s(<meta name="description" content="Practice your own mistakes.)
      # Indexable, like a puzzle; a stranger is exactly who it is for.
      refute html =~ ~s(name="robots")
      # No picture of its own: the plain card.
      refute html =~ ~s(summary_large_image)
    end
  end

  describe "the card a link unfurls as" do
    test "every page without a picture of its own is the plain summary card, as it always was",
         %{conn: conn} do
      for path <- [~p"/", ~p"/backgammon", ~p"/backgammon/123456/replay"] do
        html = conn |> get(path) |> html_response(200)
        assert html =~ ~s(<meta name="twitter:card" content="summary">), path
        refute html =~ "og:image", path
        refute html =~ "twitter:image", path
        refute html =~ "summary_large_image", path
      end
    end

    test "a page with a picture of its own gets the large card with it, at its size",
         %{conn: conn} do
      # The layout is rendered as a page with a picture renders it (the
      # puzzle page, an open invite): with the assign.
      # No page sets `:share_image` by hand in this suite:
      # the layout is rendered as that page renders it, with the assign.
      image = url(~p"/puzzles/abc12345.png")

      html =
        Phoenix.Template.render_to_string(OskolWeb.Layouts, "root", "html",
          conn: conn,
          inner_content: "",
          page_title: "White to play 6-4. What's your play?",
          share_image: image
        )

      assert html =~ ~s(<meta property="og:image" content="#{image}">)
      assert html =~ ~s(<meta property="og:image:width" content="1200">)
      assert html =~ ~s(<meta property="og:image:height" content="630">)
      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image">)
      assert html =~ ~s(<meta name="twitter:image" content="#{image}">)
      refute html =~ ~s(<meta name="twitter:card" content="summary">)
      # The picture is an absolute URL: a preview fetches it from elsewhere.
      assert image =~ ~r{^http://localhost:4002/puzzles/abc12345\.png$}
    end

    test "the layout without the assign renders the one tag the page always had", %{conn: conn} do
      html =
        Phoenix.Template.render_to_string(OskolWeb.Layouts, "root", "html",
          conn: conn,
          inner_content: ""
        )

      assert html =~ ~s(<meta name="twitter:card" content="summary">)
      refute html =~ "og:image"
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
