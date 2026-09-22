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
    # The home page is a dark board: paint its frame before the app boots,
    # so the first paint is not a flash of light paper.
    |> assign(:home, true)
    |> render_spa()
  end

  def game(conn, %{"slug" => slug}) do
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
        |> render_spa()

      # A real 404 (not a redirect): crawlers and typos should not land on
      # the library.
      :error ->
        raise OskolWeb.NotFoundError
    end
  end

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
  The practice home (`/puzzles`): what a visitor has to practise, or, for a
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
    "Practise your own mistakes. Every mistake the engine finds in a game you played " <>
      "becomes a backgammon puzzle and comes back until you stop making it. " <>
      "Every puzzle is a link anyone can open and try."
  end

  @doc """
  A puzzle's page (`/puzzles/:id`). The head is the one thing the page
  cannot supply for itself before it has fetched anything, and the one
  thing a link preview reads: the question as the title, the score and cube
  as the description. `oskol/handlers/puzzles.head` writes both, and they
  say nothing a puzzle does not say to everyone -- no name, no source game,
  no answer. A puzzle nobody stored is a 404 like an unknown game.
  """
  def puzzle(conn, %{"id" => id}) do
    case :oskol@handlers@puzzles.head(Oskol.Gleam.CtxBuilder.build(), id) do
      {:ok, {:head, title, description}} ->
        conn
        |> assign(:page_title, title)
        |> assign(:meta_description, description)
        |> assign(:canonical, url(~p"/puzzles/#{id}"))
        |> assign(:og_title, title)
        |> assign(:og_description, description)
        # The board, drawn once (Oskol.Puzzles.Pictures) and served by
        # OskolWeb.Plugs.PuzzlePicture: what the link unfurls with.
        |> assign(:puzzle_image, OskolWeb.Endpoint.url() <> "/puzzles/" <> id <> ".png")
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
