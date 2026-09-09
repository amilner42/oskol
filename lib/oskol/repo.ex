defmodule Oskol.Repo do
  use Ecto.Repo,
    otp_app: :oskol,
    adapter: Ecto.Adapters.Postgres
end
