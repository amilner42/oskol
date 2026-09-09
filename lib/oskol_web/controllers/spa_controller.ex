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
