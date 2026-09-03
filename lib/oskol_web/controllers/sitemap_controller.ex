defmodule OskolWeb.SitemapController do
  @moduledoc "The library and one landing page per game, for search engines."
  use OskolWeb, :controller

  alias Oskol.GameKit

  def index(conn, _params) do
    urls = [url(~p"/") | Enum.map(GameKit.games(), fn game -> url(~p"/#{game["slug"]}") end)]

    body =
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">),
        Enum.map(urls, fn u -> "<url><loc>#{u}</loc><changefreq>weekly</changefreq></url>" end),
        "</urlset>"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end
end
