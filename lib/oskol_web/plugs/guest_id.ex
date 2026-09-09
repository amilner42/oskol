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
  localStorage. The id is pure identity-by-convenience: it authenticates
  nothing (seats are opened by seat tokens, as ever) — losing or clearing it
  only costs the site remembering your name.
  """

  import Plug.Conn

  @cookie "_oskol_guest"
  @one_year 60 * 60 * 24 * 365
  # 16 crypto-random bytes, URL-safe base64, unpadded: exactly 22 chars.
  @id_format ~r/^[A-Za-z0-9_-]{22}$/

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    id =
      case conn.req_cookies[@cookie] do
        id when is_binary(id) ->
          if Regex.match?(@id_format, id), do: id, else: mint()

        _ ->
          mint()
      end

    conn
    # Set on every response: a returning visit renews the year.
    |> put_resp_cookie(@cookie, id, max_age: @one_year, http_only: true, same_site: "Lax")
    |> put_session(:guest_id, id)
  end

  defp mint do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
