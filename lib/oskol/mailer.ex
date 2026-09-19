defmodule Oskol.Mailer do
  @moduledoc """
  The one mailer. Postmark in production, a local mailbox in development
  (open http://localhost:4400/dev/mailbox to read what the app would have
  sent), and Swoosh's test adapter under `mix test`, where nothing leaves
  the process.

  Configured per environment under `config :oskol, Oskol.Mailer`.
  """
  use Swoosh.Mailer, otp_app: :oskol
end
