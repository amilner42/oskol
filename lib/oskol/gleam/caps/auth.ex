defmodule Oskol.Gleam.Caps.Auth do
  @moduledoc """
  Real IO for src/oskol/caps/auth.gleam. Keep field order in lockstep: a
  Gleam record is a tagged tuple, so a field out of place is a silent
  mix-up, not a compile error.

  Rows are `Oskol.Auth`, the mail is `Oskol.Mail`, the counters are
  `Oskol.Auth.Limiter`, and dropping a browser's sockets is the endpoint.
  Nothing in here decides anything.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Auth
  alias Oskol.Auth.Limiter
  alias Oskol.Mail

  def build do
    {:auth_caps, &enabled?/0, &Limiter.count/2, &issue_token/4, &send_mail/3, &verify_token/1,
     &consume_token/1, &check_code/4, &find_or_create_user/1, &user/1, &Auth.bind_guest/2,
     &Auth.unbind_guest/1, &disconnect/1}
  end

  @doc """
  Whether signing in is switched on (`:oskol, :auth_enabled`). Off, the flow
  is a polite no-op everywhere: the backend can ship before the pages do.
  """
  def enabled?, do: Application.get_env(:oskol, :auth_enabled, false) == true

  defp issue_token(email, guest_id, next, ttl_s) do
    {token, code} = Auth.issue(email, unopt(guest_id), unopt(next), ttl_s)
    {:issued, token, code}
  end

  defp send_mail(email, token, code) do
    Mail.send_login(email, OskolWeb.Endpoint.url() <> "/login/" <> token, code)
    nil
  end

  defp verify_token(token), do: opt(Auth.verify(token), &pending/1)

  defp consume_token(token), do: opt(Auth.consume(token), &pending/1)

  defp check_code(email, code, guest_id, max_attempts) do
    case Auth.check_code(email, code, unopt(guest_id) || "", max_attempts) do
      {:ok, row} -> {:code_ok, pending(row)}
      :wrong -> :code_wrong
      :dead -> :code_dead
    end
  end

  defp find_or_create_user(email), do: Auth.find_or_create_user(email) |> user_record()

  defp user(id), do: opt(Auth.user(id), &user_record/1)

  # A browser's own sockets, by the id OskolWeb.UserSocket gives them
  # ("guest:<guest id>"): logging out must not leave a tab playing a seat.
  defp disconnect(guest_id) do
    OskolWeb.Endpoint.broadcast("guest:" <> guest_id, "disconnect", %{})
    nil
  end

  defp pending(%Auth.LoginToken{} = row) do
    {:pending, row.email, opt(row.guest_id), opt(row.next)}
  end

  defp user_record(%Auth.User{} = user), do: {:user, user.id, user.email, opt(user.name)}
end
