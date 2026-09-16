defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  alias Oskol.GameKit

  @doc """
  Serves the Elm client for a running game (`/:slug/:id`) and for its replay
  (`/:slug/:id/replay`).

  Neither is gated here any more, because there is nothing in the URL to gate
  on: a seat is held by the visitor's guest cookie, and what the room will
  show this browser is the room's answer, given on the game channel. So this
  serves the shell to anyone who asks for a slug that names a game, and the
  client goes on to join the channel: a browser holding a seat lands at its
  table, and one holding none is sent to the invite link, which decides
  whether there is a seat for it at all. A `?t=` from a link minted before
  seat tokens were dropped is simply ignored.
  """
  def play(conn, %{"slug" => slug, "id" => game_id}) do
    if GameKit.exists?(slug) do
      guest_id = get_session(conn, :guest_id)

      # `elm_game` is a whole document, so it takes neither layout. Wrapped
      # in the root layout it would carry that layout's `app.js` as well as
      # its own, and a page that loads the bundle twice boots two Elm apps:
      # two sockets, two channel joins on one seat, and the second one
      # taking the seat off the first.
      conn
      |> put_root_layout(false)
      |> render(:elm_game,
        layout: false,
        game_id: game_id,
        slug: slug,
        guest_name: guest_id && Oskol.Guests.touch(guest_id)
      )
    else
      conn |> put_status(:not_found) |> put_view(OskolWeb.ErrorHTML) |> render(:"404")
    end
  end
end
