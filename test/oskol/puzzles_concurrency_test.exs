defmodule Oskol.PuzzlesConcurrencyTest do
  @moduledoc """
  One scheduled answer per opportunity, under real contention.

  Whether an answer counts is read-then-act: is this attempt row new, and is
  the card due. Four tabs answering one due card with four keys all read
  before any of them wrote, so all four found a due card and all four moved
  the ladder -- a level 0 card came out at level 4 for one puzzle answered
  once. The fix is a transaction-scoped advisory lock on the account and the
  puzzle around the whole decision.

  These commit for real rather than running in the sandbox, because the
  sandbox is exactly what hides the bug: every task in it borrows the one
  checked-out connection, so no lock is ever contended and no two writers
  ever wait. The repo goes to `:auto` and each task drops `$callers`, so
  four tasks are four database backends -- the same shape as
  `Oskol.PracticeConcurrencyTest`, and for the same reason.

  Committing for real means everything written here is really there, so it
  is all swept up again: the account (which takes its attempts with it), the
  deck, and the puzzle. A leaked `users` row is not a small thing -- the
  sign-in tests count that table.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Oskol.Gleam.CtxBuilder
  alias Oskol.Puzzles
  alias Oskol.Repo

  @puzzle "raceapzl"
  @tabs 4

  @email_prefix "puzzle-race-"

  setup do
    Sandbox.mode(Repo, :auto)
    sweep()

    on_exit(fn ->
      sweep()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  # Everything this test can have left behind, including after a crash.
  defp sweep do
    Repo.delete_all(from(p in Puzzles.Puzzle, where: p.id == ^@puzzle))

    Repo.all(from(u in Oskol.Auth.User, where: like(u.email, ^(@email_prefix <> "%"))))
    |> Enum.each(fn user ->
      Retain.delete_user(user.id)
      Repo.delete!(user)
    end)
  end

  @tag :slow
  test "four tabs answering one due card move it once" do
    {question, answer} = stored_bodies("move")
    now = DateTime.utc_now()

    Repo.insert_all(
      Puzzles.Puzzle,
      [
        %{
          id: @puzzle,
          key: "race-key",
          kind: "move",
          question: question,
          answer: answer,
          evaluated_by: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    # The deck's uid is the account's own id, as it is in production.
    uid =
      Oskol.Auth.find_or_create_user(
        "#{@email_prefix}#{System.unique_integer([:positive])}@oskol.test"
      ).id

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC", new_per_day: 10)
    {:ok, _} = Retain.put_items(uid, [%{key: @puzzle, tags: %{}, content: %{}}])
    {:ok, _} = Retain.start(uid, [@puzzle])

    # Due now, at the bottom of the ladder, so every tab sees an opportunity.
    {:ok, item} = Retain.fetch_item(uid, @puzzle)
    assert item.level == 0

    moves = path_through()

    try do
      results =
        1..@tabs
        |> Task.async_stream(
          fn n ->
            Process.delete(:"$callers")
            answer_once(uid, moves, "tab-#{n}")
          end,
          max_concurrency: @tabs,
          timeout: 60_000
        )
        |> Enum.map(fn {:ok, body} -> body end)

      # Every tab was graded and got the reveal: nothing is refused.
      assert Enum.all?(results, &match?(%{"ok" => true, "verdict" => _}, &1)),
             "expected four graded answers, got #{inspect(results)}"

      # But only one of them moved the card, and it moved one rung.
      {:ok, after_all} = Retain.fetch_item(uid, @puzzle)

      assert after_all.level == 1,
             "one answer at one opportunity should be one level, got #{after_all.level}"

      # And exactly one attempt row claims to have scheduled anything.
      scheduled =
        Repo.aggregate(
          from(a in Puzzles.Attempt, where: a.puzzle_id == ^@puzzle and a.scheduled == true),
          :count
        )

      assert scheduled == 1, "expected one scheduled attempt, got #{scheduled}"

      assert Repo.aggregate(from(a in Puzzles.Attempt, where: a.puzzle_id == ^@puzzle), :count) ==
               @tabs
    after
      sweep()
    end
  end

  # One answer, straight through the handler: no conn, because what is under
  # test is the decision and the lock behind it, not the router.
  defp answer_once(uid, moves, key) do
    :oskol@handlers@puzzles.attempt_json(
      CtxBuilder.build(),
      {:session, {:some, "guest-" <> key}, {:some, uid}},
      @puzzle,
      {:attempted, moves, :none, key},
      "",
      System.system_time(:millisecond)
    )
    |> case do
      {:ok, body} -> Jason.decode!(body)
      {:error, error} -> {:refused, error}
    end
  end

  defp stored_bodies(name) do
    {:stored, _id, _kind, question, answer} = :oskol@puzzles@fixture.stored_sample(name)
    {Jason.decode!(question), Jason.decode!(answer)}
  end

  # A whole turn, walked through the puzzle's own tree, as the page sends it.
  defp path_through do
    {_, body} = Enum.find(:oskol@puzzles@fixture.samples(), fn {n, _} -> n == "move" end)
    tree = Jason.decode!(body)["tree"]
    walk(tree["nodes"], tree["root"], [])
  end

  defp walk(nodes, id, so_far) do
    case nodes[id]["children"] do
      [] ->
        Enum.reverse(so_far)

      [child | _] ->
        walk(nodes, child["node"], [
          {child["from"], child["to"], child["die"]} | so_far
        ])
    end
  end
end
