defmodule Oskol.Release do
  @moduledoc """
  Release housekeeping. `migrate/0` runs the pending Ecto migrations; in prod
  it is invoked from application start (`:migrate_on_boot`), so a deploy needs
  no separate release_command and a machine waking from a stopped state always
  has the schema it was built against.
  """
  @app :oskol

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
