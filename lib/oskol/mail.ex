defmodule Oskol.Mail do
  @moduledoc """
  The only mail Oskol sends: a sign-in, with a link and the same sign-in as a
  six-digit code under it. Two doors in one mail, because the mail often
  opens on a different device from the one waiting to play.

  Nothing here decides anything either: the handler
  (`src/oskol/handlers/auth.gleam`) decides that a sign-in was asked for and
  hands over the address, the token and the code.

  The From address and the message stream are configuration
  (`POSTMARK_FROM`, `POSTMARK_STREAM`); the sender name is "Oskol". In
  development the mail goes to the local mailbox at `/dev/mailbox`, and the
  link and code are also logged and kept by `Oskol.Mail.LastLogin` so
  `GET /dev/last-login` can hand them to a browser test.

  A token is never logged in production. `Logger` sees the link only in dev,
  where the whole point is to click it.
  """

  require Logger

  import Swoosh.Email

  alias Oskol.Mail.LastLogin
  alias Oskol.Mailer

  @doc """
  Post a sign-in to `email`: `link` opens `/login/<token>`, `code` is the six
  digits printed under it. Both are good for the fifteen minutes the handler
  gave them.

  Never raises: a mail that cannot be posted is logged, and the player can
  ask again. Their answer said nothing about it either way.
  """
  def send_login(email, link, code) do
    LastLogin.put(%{email: email, link: link, code: code})

    if local_mailbox?() do
      # The one place a link is allowed in the log, so a developer can click
      # it straight out of the terminal.
      Logger.info("SIGN-IN for #{email}: #{link} (code #{spaced(code)})")
    end

    new()
    |> to(email)
    |> from({"Oskol", from_address()})
    |> subject("Sign in to Oskol")
    |> text_body(text(link, code))
    |> html_body(html(link, code))
    |> stream()
    |> Mailer.deliver()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # The address, never the token: a log line is not a credential store.
        Logger.error("SIGN-IN MAIL FAILED for #{email}: #{inspect(reason)}")
        :error
    end
  rescue
    e ->
      Logger.error("SIGN-IN MAIL FAILED for #{email}: #{Exception.message(e)}")
      :error
  end

  # Postmark puts a message on a stream; other adapters ignore the option.
  defp stream(email) do
    case Application.get_env(:oskol, :postmark_stream) do
      stream when is_binary(stream) and stream != "" ->
        put_provider_option(email, :message_stream, stream)

      _ ->
        email
    end
  end

  defp from_address do
    Application.get_env(:oskol, :mail_from) || "hello@oskol.io"
  end

  # Only the local mailbox (development) gets the link in the log; Postmark
  # and the test adapter never do.
  defp local_mailbox? do
    Application.get_env(:oskol, Oskol.Mailer, []) |> Keyword.get(:adapter) ==
      Swoosh.Adapters.Local
  end

  # "482 913" reads back off a screen; "482913" does not.
  defp spaced(code) do
    case String.split_at(code, 3) do
      {first, rest} when rest != "" -> first <> " " <> rest
      _ -> code
    end
  end

  defp text(link, code) do
    """
    Tap to sign in:

    #{link}

    Or enter this code: #{spaced(code)}

    Both work for 15 minutes. If you didn't ask for this, ignore it.

    Oskol — backgammon, from a link.
    """
  end

  defp html(link, code) do
    """
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5;color:#1d2230;max-width:480px">
      <p style="margin:0 0 24px">Tap to sign in to Oskol.</p>
      <p style="margin:0 0 24px">
        <a href="#{link}" style="display:inline-block;background:#1d2230;color:#f7f4ea;text-decoration:none;padding:14px 28px;border-radius:6px;font-weight:600">Sign in</a>
      </p>
      <p style="margin:0 0 8px">Or enter this code:</p>
      <p style="margin:0 0 24px;font-size:28px;font-weight:700;letter-spacing:4px">#{spaced(code)}</p>
      <p style="margin:0 0 24px;color:#5b6172">Both work for 15 minutes. If you didn't ask for this, ignore it.</p>
      <p style="margin:0;color:#5b6172;font-size:14px">Oskol — backgammon, from a link.</p>
    </div>
    """
  end
end
