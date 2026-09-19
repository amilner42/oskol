defmodule OskolWeb.LoginController do
  @moduledoc """
  `GET /login/<token>` — the page a mailed sign-in link opens.

  It is a server route because a mail client opens it as a top-level
  navigation (which is what the `SameSite=Lax` guest cookie needs), and
  because the browser that opens it is the browser to be signed in.

  **It writes nothing.** It reads the token and serves the Elm shell with
  flags saying either "this is a live sign-in for you@example.com" or "that
  link has expired". Signing in is the button on that page, which POSTs to
  `/papi/auth/link` with the page's CSRF token. So:

    * a mail scanner that prefetches links cannot burn one;
    * a link opened twice still works the first time it is *used*;
    * no other site can sign a visitor in by pointing an image at a URL.

  The page is `noindex`, and a token is never in a title, a canonical or a
  log line.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder

  def show(conn, %{"token" => token}) do
    conn
    |> assign(:page_title, "Sign in")
    |> assign(:no_index, true)
    # Everything the page needs to render, decided in Gleam:
    # {"state": "confirm", "email", "next"} or {"state": "expired"}.
    |> assign(:login, :oskol@handlers@auth.link_flags(CtxBuilder.build(), token))
    |> assign(:guest_name, guest_name(conn))
    # The same shell every other client route is served.
    |> put_view(OskolWeb.SpaHTML)
    |> render(:spa)
  end

  defp guest_name(conn) do
    case get_session(conn, :guest_id) do
      guest_id when is_binary(guest_id) -> Oskol.Guests.touch(guest_id)
      _ -> nil
    end
  end
end
