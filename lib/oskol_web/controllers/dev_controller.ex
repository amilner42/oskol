defmodule OskolWeb.DevController do
  @moduledoc """
  Development-only endpoints. The router only declares them when
  `:dev_routes` is on, so they do not exist in production or under `mix
  test` — there is no route to guess at.

  `GET /dev/last-login` hands back the last sign-in this node put in the
  mail (`{link, code, email}`), which is how a browser test reads a mailed
  link without a mailbox. The same mail is readable by eye at
  `/dev/mailbox`.
  """
  use OskolWeb, :controller

  alias Oskol.Mail.LastLogin

  def last_login(conn, _params) do
    case LastLogin.get() do
      %{email: email, link: link, code: code} ->
        json(conn, %{ok: true, email: email, link: link, code: code})

      _ ->
        conn |> put_status(:not_found) |> json(%{ok: false, error: "no sign-in has been sent"})
    end
  end
end
