defmodule OskolWeb.Plugs.PuzzlePicture do
  @moduledoc """
  `GET /puzzles/:id.png`: the board a puzzle's link unfurls with.

  An endpoint plug beside `Plug.Static` rather than a route, for two
  reasons. The router's grammar has no `:id.png` (a dynamic segment is one
  parameter, whole), and `/puzzles/:id` is the puzzle page's; and a public,
  immutable image has no use for the browser pipeline -- no session, no
  guest cookie to mint or renew, no CSRF, no layout -- so serving it before
  the router is what keeps it a couple of milliseconds warm.

  It draws nothing. A puzzle with its picture stored is served with a
  year's cache and `immutable` (a puzzle's picture never changes: its
  question is its key). One without -- not drawn yet, or given up on -- is
  served the site's default board with a short cache, so a preview still
  shows a board and the real one takes over once it exists. A `?s=` story
  token is ignored: the story is in the title, not the picture. An id that
  names no puzzle is a 404.
  """

  @behaviour Plug

  import Plug.Conn

  alias Oskol.Puzzles.Pictures

  @immutable "public, max-age=31536000, immutable"
  @short "public, max-age=300"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["puzzles", name]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    case picture_id(name) do
      {:ok, id} -> serve(conn, id)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  # Only a name of the shape a puzzle id has, with the suffix: anything else
  # is the page's, or nobody's.
  defp picture_id(name) do
    case String.split(name, ".png") do
      [id, ""] when id != "" -> {:ok, id}
      _ -> :error
    end
  end

  defp serve(conn, id) do
    case Pictures.png(id) do
      {:ok, png} ->
        send_png(conn, png, @immutable)

      :none ->
        if Pictures.exists?(id) do
          send_png(conn, Pictures.default_png(), @short)
        else
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(404, "Not found")
          |> halt()
        end
    end
  end

  defp send_png(conn, png, cache_control) do
    etag = ~s("#{Base.encode16(:crypto.hash(:sha256, png), case: :lower)}")

    conn =
      conn
      |> put_resp_header("cache-control", cache_control)
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      conn |> send_resp(304, "") |> halt()
    else
      conn
      |> put_resp_content_type("image/png", nil)
      |> send_resp(200, png)
      |> halt()
    end
  end
end
