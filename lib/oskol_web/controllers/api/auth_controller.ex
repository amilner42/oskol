defmodule OskolWeb.Api.AuthController do
  @moduledoc """
  Signing in, as JSON:

      POST /papi/auth/start   {email, next?}  ask for the mail
      POST /papi/auth/link    {token}         spend the link's token
      POST /papi/auth/code    {email, code}   spend the six digits
      POST /papi/auth/logout                  be a guest again
      GET  /papi/me                           who this browser is

  Every write is a POST through the `:papi` pipeline, so it carries the
  page's CSRF token: **signing in is never something a GET does**. The
  mailed link's `GET /login/<token>` reads the token and renders a button;
  this is what the button posts to.

  Every decision lives in `src/oskol/handlers/auth.gleam`. What is left here
  is the one thing a handler cannot do: renewing the session cookie the
  moment a sign-in succeeds, so a fixated session id is worth nothing.
  """
  use OskolWeb, :controller

  alias Oskol.Gleam.CtxBuilder
  alias Oskol.Auth.SourceKey

  def start(conn, params) do
    send_json(
      conn,
      :oskol@handlers@auth.start_json(
        ctx(),
        session(conn),
        param(params, "email"),
        param(params, "next"),
        source_key(conn)
      )
    )
  end

  def link(conn, params) do
    sign_in(
      conn,
      :oskol@handlers@auth.link_json(ctx(), session(conn), param(params, "token"))
    )
  end

  def code(conn, params) do
    sign_in(
      conn,
      :oskol@handlers@auth.code_json(
        ctx(),
        session(conn),
        param(params, "email"),
        param(params, "code")
      )
    )
  end

  def logout(conn, _params) do
    body = :oskol@handlers@auth.logout_json(ctx(), session(conn))

    conn
    # The browser keeps its guest cookie (it is still holding seats as a
    # guest); what it loses is the account on it, and a fresh session id.
    |> configure_session(renew: true)
    |> json_resp(200, body)
  end

  def me(conn, _params) do
    json_resp(conn, 200, :oskol@handlers@auth.me_json(ctx(), session(conn)))
  end

  def rename(conn, params) do
    send_json(conn, :oskol@handlers@auth.name_json(ctx(), session(conn), param(params, "name")))
  end

  # A sign-in that took hands back `renew: true`, which is the moment to
  # renew the session (a session id someone else planted is no longer the
  # signed-in one) and, with it, the fresh guest id the handler minted: the
  # browser's row and its seats have already moved to it, so the cookie must
  # move too, in this very response.
  defp sign_in(conn, {:signed_in, renew, guest_id, drop_sockets, result}) do
    conn =
      conn
      |> then(fn conn -> if renew, do: configure_session(conn, renew: true), else: conn end)
      |> then(fn conn ->
        case guest_id do
          {:some, id} -> OskolWeb.Plugs.GuestId.put_guest(conn, id)
          :none -> conn
        end
      end)
      |> send_json(result)

    # Only now, with the response (and its cookie) sent, and a moment for
    # the browser to take the cookie in: a socket dropped earlier could
    # reconnect on the old cookie before the new one arrived.
    case drop_sockets do
      {:some, old_guest_id} -> drop_sockets_later(old_guest_id)
      :none -> :ok
    end

    conn
  end

  @socket_drop_delay_ms 500

  defp drop_sockets_later(guest_id) do
    Task.start(fn ->
      Process.sleep(@socket_drop_delay_ms)
      OskolWeb.Endpoint.broadcast("guest:" <> guest_id, "disconnect", %{})
    end)
  end

  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

  # Fly's proxy supplies exactly one Fly-Client-IP. Without it, there is no
  # trustworthy visitor address: omit the source bucket rather than treating
  # Fly's peer IP as every visitor. A boot-secret HMAC keeps the ephemeral ETS
  # key opaque; raw addresses are never stored or logged.
  defp source_key(conn) do
    case get_req_header(conn, "fly-client-ip") do
      [ip] ->
        case :inet.parse_address(String.to_charlist(ip)) do
          {:ok, address} -> {:some, address |> :inet.ntoa() |> to_string() |> SourceKey.key()}
          {:error, _} -> :none
        end

      _ ->
        :none
    end
  end

  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp send_json(conn, {:ok, body}), do: json_resp(conn, 200, body)

  defp send_json(conn, {:error, error}) do
    {status, body} = :oskol@core@envelope.error(error)
    json_resp(conn, status, body)
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
