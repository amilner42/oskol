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

  def start(conn, params) do
    send_json(
      conn,
      :oskol@handlers@auth.start_json(
        ctx(),
        session(conn),
        param(params, "email"),
        param(params, "next")
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

  # A sign-in that took hands back `true`, which is the moment to renew the
  # session: a session id someone else planted is no longer the signed-in one.
  defp sign_in(conn, {signed_in, result}) do
    conn
    |> then(fn conn -> if signed_in, do: configure_session(conn, renew: true), else: conn end)
    |> send_json(result)
  end

  defp ctx, do: CtxBuilder.build()

  defp session(conn), do: CtxBuilder.session(conn)

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
