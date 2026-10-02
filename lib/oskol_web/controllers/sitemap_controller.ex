defmodule OskolWeb.SitemapController do
  @moduledoc """
  The library, one landing page per game, the practice home, the analysis
  board and the sets of
  puzzles that have something built (`/practice/openings`...), for search
  engines. A tier of somebody's mistakes is nobody else's page and is never
  listed.
  """
  use OskolWeb, :controller

  alias Oskol.GameKit

  def index(conn, _params) do
    urls =
      [url(~p"/") | Enum.map(GameKit.games(), fn game -> url(~p"/#{game["slug"]}") end)] ++
        [url(~p"/puzzles"), url(~p"/analysis")] ++
        Enum.map(
          :oskol@handlers@practice.indexed_slugs(Oskol.Gleam.CtxBuilder.build()),
          fn slug -> url(~p"/practice/#{slug}") end
        )

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
