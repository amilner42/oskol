defmodule OskolWeb.Plugs.GuestIdTest do
  # No database assertions here: minting and renewing are pure conn work.
  use OskolWeb.ConnCase, async: true

  @cookie "_oskol_guest"
  @one_year 60 * 60 * 24 * 365

  test "a first visit mints a guest cookie and mirrors it into the session", %{conn: conn} do
    conn = get(conn, ~p"/")

    cookie = conn.resp_cookies[@cookie]
    assert %{value: id, max_age: @one_year, http_only: true, same_site: "Lax"} = cookie
    # 16 crypto-random bytes, URL-safe base64, unpadded.
    assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
    assert get_session(conn, :guest_id) == id
  end

  test "a returning visit keeps the id and renews the cookie's year", %{conn: conn} do
    id = get(conn, ~p"/").resp_cookies[@cookie].value

    conn = build_conn() |> put_req_cookie(@cookie, id) |> get(~p"/")

    assert %{value: ^id, max_age: @one_year} = conn.resp_cookies[@cookie]
    assert get_session(conn, :guest_id) == id
  end

  test "a mangled cookie is replaced, never trusted", %{conn: conn} do
    conn = conn |> put_req_cookie(@cookie, "not!a!valid!guest!id") |> get(~p"/")

    id = conn.resp_cookies[@cookie].value
    assert id =~ ~r/^[A-Za-z0-9_-]{22}$/
    assert get_session(conn, :guest_id) == id
  end
end
