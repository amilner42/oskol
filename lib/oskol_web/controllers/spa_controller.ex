defmodule OskolWeb.SpaController do
  @moduledoc """
  The front door: `/` and `/:slug` serve the Elm app, which routes both of
  them client-side (`assets/src/Route.elm`) and reads its data from `/papi`.

  What is left for the server is what a crawler and a first paint need and
  a client-side route cannot supply: the title, the description, the
  canonical URL, the Open Graph pair and the JSON-LD, all rendered into the
  document head by the root layout.

  Guest identity is untouched by any of this. `OskolWeb.Plugs.GuestId` mints
  the cookie on the way through the browser pipeline exactly as it did for
  the LiveView, this action touches the guest's row on the way out, and the
  name they last played under rides into the app in a meta tag so the create
  form is prefilled on the first paint rather than a round trip later.
  """
  use OskolWeb, :controller

  alias Oskol.GameKit
  alias OskolWeb.GameCopy

  def library(conn, _params) do
    site = GameCopy.site()

    conn
    |> assign(:page_title, site.title)
    |> assign(:meta_description, site.description)
    |> assign(:canonical, url(~p"/"))
    |> assign(:json_ld, library_json_ld())
    # `/` cannot say which home it is until the app asks who this is, so
    # the first paint is the loading bar the app starts on.
    |> assign(:home, true)
    |> render_spa()
  end

  def game(conn, %{"slug" => slug} = params) do
    case GameKit.game_info(slug) do
      {:ok, info} ->
        copy = GameCopy.for_game(info)

        conn
        |> assign(:page_title, copy.title)
        |> assign(:meta_description, copy.description)
        |> assign(:canonical, url(~p"/#{slug}"))
        |> assign(:og_title, copy.title)
        |> assign(:og_description, copy.description)
        |> assign(:json_ld, game_json_ld(info, copy))
        |> invite_head(slug, params["game"])
        |> render_spa()

      # A real 404 (not a redirect): crawlers and typos should not land on
      # the library.
      :error ->
        raise OskolWeb.NotFoundError
    end
  end

  # An invite link (`?game=`) to a room waiting for its second player
  # unfurls as the invitation it is: who wants to play what, in Gleam's
  # words from the room's row (nothing wakes a room for a crawler), and the
  # board's picture. Any other room, and the bare game page, keep the game's
  # own head; the canonical stays the game page either way, so an invite
  # never competes with it.
  defp invite_head(conn, slug, game_id) when is_binary(game_id) do
    case :oskol@handlers@landing.invite_head(Oskol.Gleam.CtxBuilder.build(), slug, game_id) do
      {:some, {title, description}} ->
        conn
        |> assign(:page_title, title)
        |> assign(:og_title, title)
        |> assign(:meta_description, description)
        |> assign(:og_description, description)
        |> assign(:share_image, url(~p"/images/invite-board.png"))

      :none ->
        conn
    end
  end

  # No `?game=`, or one that is not a string (`?game[]=`): the game page.
  defp invite_head(conn, _slug, _), do: conn

  @doc """
  A room's replay (`/:slug/:id/replay`). It needs no seat: the Elm client
  reads the record and the analysis from `/papi`, which are open to anyone
  with the room, and turns the board to whichever seat the link's token
  names, if it names one.
  """
  def replay(conn, %{"slug" => slug}) do
    case GameKit.game_info(slug) do
      {:ok, info} ->
        copy = GameCopy.for_game(info)

        conn
        |> assign(:page_title, "Replay · " <> copy.title)
        |> assign(:meta_description, copy.description)
        # A room is nobody else's business to index; the page is still open
        # to anyone who has the link.
        |> assign(:no_index, true)
        |> render_spa()

      :error ->
        raise OskolWeb.NotFoundError
    end
  end

  @doc """
  The practice home (`/puzzles`): what a visitor has to practice, or, for a
  stranger, what this is and one puzzle to try. The page reads everything
  from `/papi/practice`; the head is the one thing it cannot supply, and
  it says the same to everyone.
  """
  def puzzles(conn, _params) do
    conn
    |> assign(:page_title, puzzles_title())
    |> assign(:meta_description, puzzles_description())
    |> assign(:canonical, url(~p"/puzzles"))
    |> assign(:og_title, puzzles_title())
    |> assign(:og_description, puzzles_description())
    |> render_spa()
  end

  def puzzles_title, do: "Puzzles"

  def puzzles_description do
    "Practice your own mistakes. Every mistake the engine finds in a game you played " <>
      "becomes a backgammon puzzle and comes back until you stop making it. " <>
      "Every puzzle is a link anyone can open and try."
  end

  @doc """
  The analysis board (`/analysis`): a position set up by tapping, asked of
  the engine on a press. The same head for everyone, whatever position the
  URL carries (`?xgid=`, `?p=`): the page is the board, not the position.
  """
  def analysis(conn, _params) do
    conn
    |> assign(:page_title, analysis_title())
    |> assign(:meta_description, analysis_description())
    |> assign(:canonical, url(~p"/analysis"))
    |> assign(:og_title, analysis_title())
    |> assign(:og_description, analysis_description())
    |> render_spa()
  end

  def analysis_title, do: "Analysis"

  def analysis_description,
    do: "Set up any backgammon position and ask the engine what it would play."

  @doc """
  A deck's page (`/practice/:slug`): one of the three tiers of a player's
  mistakes, or one of the universal sets. `oskol/handlers/practice.deck_head`
  writes the title and description and says whether the page may be
  indexed: a set is the same page for everyone and is (with a canonical, and
  in the sitemap); a tier is somebody's own mistakes and is not, and nor is
  a player's own set, which is its owner's page alone. A slug that names
  no deck, a set nobody has built, and somebody else's own set are a 404.
  """
  def practice(conn, %{"slug" => slug}) do
    ctx = Oskol.Gleam.CtxBuilder.build()

    case :oskol@handlers@practice.deck_head(ctx, Oskol.Gleam.CtxBuilder.session(conn), slug) do
      {:ok, {:deck_head, title, description, true}} ->
        conn
        |> assign(:page_title, title)
        |> assign(:meta_description, description)
        |> assign(:canonical, url(~p"/practice/#{slug}"))
        |> assign(:og_title, title)
        |> assign(:og_description, description)
        |> render_spa()

      {:ok, {:deck_head, title, description, false}} ->
        conn
        |> assign(:page_title, title)
        |> assign(:meta_description, description)
        |> assign(:no_index, true)
        |> render_spa()

      {:error, _} ->
        raise OskolWeb.NotFoundError
    end
  end

  @doc """
  A puzzle's page (`/puzzles/:id`). The head is the one thing the page
  cannot supply for itself before it has fetched anything, and the one
  thing a link preview reads: the question as the title, the score and cube
  as the description. `oskol/handlers/puzzles.head` writes both, and they
  say nothing a puzzle does not say to everyone -- no name, no source game,
  no answer. A puzzle nobody stored is a 404 like an unknown game.

  `?s=<token>` is a story link (`oskol/handlers/shares`): the title becomes
  "Arie got this wrong. What's your play?" where the token opens a story
  for this puzzle, and nothing changes where it does not. The canonical
  URL stays the clean one either way, so a search engine sees one page.
  """
  def puzzle(conn, %{"id" => id} = params) do
    share =
      case Map.get(params, "s") do
        token when is_binary(token) -> token
        _ -> ""
      end

    case :oskol@handlers@puzzles.head(Oskol.Gleam.CtxBuilder.build(), id, share) do
      {:ok, {:head, title, description}} ->
        conn
        |> assign(:page_title, title)
        |> assign(:meta_description, description)
        |> assign(:canonical, url(~p"/puzzles/#{id}"))
        |> assign(:og_title, title)
        |> assign(:og_description, description)
        # The board, drawn once (Oskol.Puzzles.Pictures) and served by
        # OskolWeb.Plugs.PuzzlePicture: what the link unfurls with.
        |> assign(:share_image, OskolWeb.Endpoint.url() <> "/puzzles/" <> id <> ".png")
        |> render_spa()

      {:error, _} ->
        raise OskolWeb.NotFoundError
    end
  end

  defp render_spa(conn) do
    guest_id = get_session(conn, :guest_id)
    guest_name = if guest_id, do: Oskol.Guests.touch(guest_id)

    conn
    |> assign(:guest_name, guest_name)
    |> render(:spa)
  end

  # Structured data for search engines: the catalog, and one game. Encoded
  # HTML-safe because it is rendered raw inside a <script> tag.
  defp library_json_ld do
    json_ld(%{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "Oskol",
      "url" => url(~p"/"),
      "description" => GameCopy.site().description,
      "hasPart" =>
        Enum.map(GameKit.games(), fn game ->
          %{"@type" => "VideoGame", "name" => game["name"], "url" => url(~p"/#{game["slug"]}")}
        end)
    })
  end

  defp game_json_ld(info, copy) do
    json_ld(%{
      "@context" => "https://schema.org",
      "@type" => "VideoGame",
      "name" => info["name"],
      "url" => url(~p"/#{info["slug"]}"),
      "description" => copy.description,
      "applicationCategory" => "Game",
      "operatingSystem" => "Web",
      "numberOfPlayers" => 2,
      "playMode" => "MultiPlayer",
      "isAccessibleForFree" => true,
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
    })
  end

  defp json_ld(data), do: Jason.encode!(data, escape: :html_safe)
end
