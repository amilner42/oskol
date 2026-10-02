defmodule OskolWeb.PracticePageTest do
  @moduledoc """
  A deck's page (`/practice/:slug`) as a crawler and a cold load see it: the
  shell, with the head `oskol/handlers/practice.deck_head` writes. A set is
  indexable, with a canonical, and in the sitemap; a tier is somebody's own
  mistakes and is `noindex`; a slug that names no deck, and a set nobody has
  built, is a 404. The decisions are tested in Gleam
  (test/oskol/catalog_test.gleam); this is the wiring, on real built sets.
  """
  use OskolWeb.ConnCase, async: false

  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp build_sets do
    Req.Test.stub(Oskol.Reviews, &Oskol.CompleteEngine.respond/1)
    [_, _] = Oskol.Decks.build(true)
    :ok
  end

  describe "with the sets built" do
    setup do
      Req.Test.set_req_test_to_shared()
      build_sets()
    end

    test "a set's page is indexable, with its name, its line and a canonical", %{conn: conn} do
      html = conn |> get(~p"/practice/openings") |> html_response(200)
      assert html =~ ~s(id="elm-app")
      assert html =~ ~s(>Openings · Practice · Oskol</title>)

      assert html =~
               ~s(<meta name="description" content="The fifteen opening rolls, and the play for each.")

      assert html =~ ~s(<link rel="canonical" href="http://localhost:4002/practice/openings")
      assert html =~ ~s(<meta property="og:title" content="Openings · Practice")
      refute html =~ ~s(name="robots")

      replies = conn |> get(~p"/practice/opening-replies") |> html_response(200)
      assert replies =~ ~s(>Opening replies · Practice · Oskol</title>)

      assert replies =~
               ~s(<link rel="canonical" href="http://localhost:4002/practice/opening-replies")

      refute replies =~ ~s(name="robots")
    end

    test "a tier's page is somebody's own mistakes: noindex and no canonical", %{conn: conn} do
      for {slug, name} <- [
            {"very-bad", "Very bad moves"},
            {"bad", "Bad moves"},
            {"dubious", "Dubious moves"}
          ] do
        html = conn |> get(~p"/practice/#{slug}") |> html_response(200)
        assert html =~ ~s(id="elm-app")
        assert html =~ ~s(>#{name} · Practice · Oskol</title>)
        assert html =~ ~s(<meta name="robots" content="noindex")
        assert html =~ ~s(and how many you have stopped making.)
        refute html =~ ~s(rel="canonical")
      end
    end

    test "the sitemap lists the two sets and none of the tiers", %{conn: conn} do
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      assert body =~ "<loc>http://localhost:4002/practice/openings</loc>"
      assert body =~ "<loc>http://localhost:4002/practice/opening-replies</loc>"
      refute body =~ "/practice/very-bad"
      refute body =~ "/practice/bad"
      refute body =~ "/practice/dubious"
    end

    test "a slug that names no deck is a 404, and so is a bare /practice", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/practice/nothing") end
      # The wire's id is not the page's slug.
      assert_error_sent 404, fn -> get(conn, ~p"/practice/very_bad") end
      assert_error_sent 404, fn -> get(conn, ~p"/practice") end
    end
  end

  describe "with nothing built" do
    test "a set nobody has built has no page and is not in the sitemap", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/practice/openings") end
      body = conn |> get(~p"/sitemap.xml") |> response(200)
      refute body =~ "/practice/"
      # A tier's page is there whatever is built: it is the player's own.
      assert conn |> get(~p"/practice/very-bad") |> html_response(200) =~ ~s(id="elm-app")
    end
  end
end
