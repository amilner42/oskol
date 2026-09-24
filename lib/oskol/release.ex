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
  Put every mistake back in the queue worst first -- the one-off behind
  `mix oskol.puzzles.reposition`, for a release that has no mix:

      bin/oskol eval 'Oskol.Release.reposition_puzzles(dry_run: true)'
      bin/oskol eval 'Oskol.Release.reposition_puzzles(dry_run: false)'

  Reads and writes nothing on a dry run, and is a no-op the second time:
  a card already in its place is left alone. Only the order new mistakes
  are introduced in changes; nothing anybody has learned is touched.
  """
  def reposition_puzzles(opts \\ []) do
    write? = Keyword.get(opts, :dry_run, true) == false
    limit = Keyword.get(opts, :limit, 10_000)
    Application.load(@app)

    {:ok, totals, _} =
      Ecto.Migrator.with_repo(Oskol.Repo, fn _repo ->
        Oskol.Practice.reposition(limit, write?)
      end)

    IO.puts(
      "#{totals.accounts} decks, #{totals.cards} mistakes read, #{totals.moved} " <>
        if(write?, do: "moved", else: "would move (dry run)")
    )

    totals
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

  @doc """
  Fill the mistakes decks that are owed one, from a release.

      bin/oskol eval 'Oskol.Release.puzzles_sync(dry_run: true)'
      bin/oskol eval 'Oskol.Release.puzzles_sync(dry_run: false, reset: true)'

  The same sweep the review queue runs every minute; this is for looking,
  and for draining a backlog now rather than within the minute. `reset:`
  first lets the rows that gave up be tried again. A bare `eval` VM runs
  no queue, so nothing races it.
  """
  def puzzles_sync(opts \\ []) do
    write? = Keyword.get(opts, :dry_run, true) == false
    Application.load(@app)

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Oskol.Repo, fn _repo ->
        if Keyword.get(opts, :reset, false) do
          IO.puts("#{Oskol.Practice.reset()} rows reopened")
        end

        pending = Oskol.Practice.pending(Keyword.get(opts, :limit, Oskol.Practice.sweep_batch()))
        Enum.each(pending, &IO.puts("#{&1.user_id}: #{&1.sources} mistakes"))

        if write?, do: Oskol.Practice.sweep(), else: %{accounts: 0, added: 0, failed: 0}
      end)

    IO.puts(
      "#{result.accounts} decks filled, #{result.added} new cards, " <>
        "#{result.failed} refused#{if write?, do: "", else: " (dry run)"}"
    )

    result
  end

  @doc """
  The puzzles backfill, from a release: re-ask the engine about every game
  graded before it sent every legal result, replace the answer and the
  page, write the puzzles complete and sync the decks.

      bin/oskol eval 'Oskol.Release.puzzles_backfill(dry_run: true)'
      bin/oskol eval 'Oskol.Release.puzzles_backfill(dry_run: false)'
      bin/oskol eval 'Oskol.Release.puzzles_backfill(dry_run: false, room: "821900", limit: 1)'

  `reset: true` first lets games whose three tries are spent be asked
  again. A bare `eval` VM runs no queue, so nothing races it; the live
  app's queue is another VM, and its sweep never touches a `done` game
  whose marker is set, which every game is until this reopens it and
  writes it back in the same call.
  """
  def puzzles_backfill(opts \\ []) do
    write? = Keyword.get(opts, :dry_run, true) == false
    Application.load(@app)
    # The engine is reached over HTTP, which a bare `eval` VM has not
    # started; the repo alone is not enough here.
    {:ok, _} = Application.ensure_all_started(:req)

    {:ok, totals, _} =
      Ecto.Migrator.with_repo(Oskol.Repo, fn _repo ->
        Oskol.Puzzles.Backfill.run(
          write: write?,
          room: Keyword.get(opts, :room),
          limit: Keyword.get(opts, :limit),
          reset: Keyword.get(opts, :reset, false)
        )
      end)

    totals
  end
end
