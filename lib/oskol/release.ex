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

  @doc """
  Look over (or, with `dry_run: false`, rewrite) the backgammon logs from
  before the between-games READY (`Oskol.Game.ReadyUpPatch`). The boot-time
  migration already ran it once; this is for reading what it did, or would
  do, in a release that has no mix:

      bin/oskol eval 'Oskol.Release.patch_ready_up(dry_run: true)'

  Prints one line per room. A bare `eval` VM runs no rooms, so it cannot see
  a room that is live on the server: write only when none of the rooms it
  names is in play.
  """
  def patch_ready_up(opts \\ []) do
    write? = Keyword.get(opts, :dry_run, true) == false
    Application.load(@app)

    {:ok, reports, _} =
      Ecto.Migrator.with_repo(Oskol.Repo, fn _repo ->
        Oskol.Game.ReadyUpPatch.run(write: write?)
      end)

    Enum.each(reports, &IO.puts(Oskol.Game.ReadyUpPatch.describe(&1)))
    IO.puts("#{length(reports)} rooms, #{if write?, do: "written", else: "dry run"}")
    reports
  end
end
