defmodule OskolWeb.Plugs.GuestId do
  @moduledoc """
  Every visitor silently becomes a guest: on their first request this plug
  mints an opaque crypto-random id, sets it as a year-long cookie, and every
  later visit renews the cookie's clock. The id also goes into the session,
  which is how a LiveView sees it at mount — on the static render already,
  so a saved name can prefill a form with no JS round-trip.

  Why a server-minted cookie rather than localStorage:

    * it is visible on the very first server render (localStorage needs a
      connected LiveView hook and a round-trip);
    * it works before and without JS, and on the crawl-style requests the
      static render serves;
    * `HttpOnly` keeps it out of reach of page scripts entirely.

  Nothing here needs the id client-side, so it is not mirrored into
  localStorage — and it must not be: `HttpOnly` is what keeps it out of
  reach of a page script, and the id is what holds a seat. A browser plays
  the games its guest sat down at; losing or clearing the cookie loses the
  name the site remembered and the seats it was holding, which can then be
  claimed back from the invite link like anyone else's.

  It is also the identity accounts will grow out of: `guests.user_id` is
  where a guest becomes a user, and a seat held by the guest is a seat that
  becomes held by the account with no second mechanism beside it.
  """

  import Plug.Conn

  alias Oskol.Gleam.CtxBuilder
  alias Oskol.Gleam.Interop

  @cookie "_oskol_guest"
  @one_year 60 * 60 * 24 * 365

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    # Which id this request carries — the cookie's, or a fresh one when it is
    # not one we minted — is decided in Gleam (oskol/guests/identity).
    id =
      :oskol@guests@identity.for_request(
        CtxBuilder.build(),
        Interop.opt(conn.req_cookies[@cookie])
      )

    conn
    # Set on every response: a returning visit renews the year.
    |> put_resp_cookie(@cookie, id, max_age: @one_year, http_only: true, same_site: "Lax")
    |> put_session(:guest_id, id)
  end
end
