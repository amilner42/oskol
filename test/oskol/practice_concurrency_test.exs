defmodule Oskol.PracticeConcurrencyTest do
  @moduledoc """
  The practice cap under real contention.

  These commit for real rather than running in the sandbox, because the sandbox is exactly what
  hides the bug they are looking for: every task in it borrows the one checked-out connection,
  so no row lock is ever contended and two writers never wait for each other. The repo goes to
  `:auto` and each task drops `$callers`, so eight tasks are eight database backends.

  That also means these tests leave rows behind if they die, so they sweep their own prefix on
  the way in.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Oskol.Gleam.Caps.Practice
  alias Oskol.Repo

  @prefix "practice-race-"

  setup do
    Sandbox.mode(Repo, :auto)
    Repo.delete_all(from(u in Retain.User, where: like(u.uid, ^(@prefix <> "%"))))
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  @tag :slow
  test "two ways into one deck at once do not deadlock" do
    # `start` and `master` both touch many cards of one account, and a player can easily cause
    # both at once: a game ends and files its mistakes while they are practising. The two used
    # to take their row locks in different orders -- introduction order and the caller's key
    # order -- so each could hold the row the other wanted next, and Postgres killed one.
    {:practice_caps, put_user, put_items, _, start, _, _, _, _, _, master, _, _, _} =
      Practice.build()

    uid = "#{@prefix}#{System.unique_integer([:positive])}"
    keys = Enum.map(1..40, &"pos:#{&1}")

    try do
      {:ok, nil} = put_user.(uid, "Etc/UTC", 10)
      {:ok, 40} = put_items.(uid, Enum.map(keys, &{:item, &1, [], "{}", :none}))

      results =
        1..8
        |> Task.async_stream(
          fn n ->
            Process.delete(:"$callers")
            # Opposite key orders, which is what made the old lock orders diverge.
            ordered = if rem(n, 2) == 0, do: keys, else: Enum.reverse(keys)
            if rem(n, 2) == 0, do: start.(uid, ordered), else: master.(uid, ordered)
          end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, n} -> n end)

      # Every call came back with a count rather than a deadlock.
      assert Enum.all?(results, &is_integer/1), "expected counts, got #{inspect(results)}"

      # And whatever order they landed in, the log is still the truth for every card.
      live = snapshot(uid, keys)
      assert {:ok, _} = Retain.rebuild(uid)
      assert snapshot(uid, keys) == live
    after
      Retain.delete_user(uid)
    end
  end

  defp snapshot(uid, keys) do
    Map.new(keys, fn key ->
      {:ok, item} = Retain.fetch_item(uid, key)
      {key, Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])}
    end)
  end
end
