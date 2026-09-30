defmodule Oskol.ReviewsRebuildTest do
  @moduledoc """
  Building again the reviews that came back empty.

  Ending an unlimited session used to read as a second game ending, and the
  empty half of that overwrote the real answer: the row was left `done` with
  `turns: 0` and a played game read "Nothing to analyse". The guard is in
  `backgammon/analysis`; this is the sweep that repairs what it wrote
  (`bg-session-close-wiped-reviews`).
  """
  use OskolWeb.ConnCase, async: false

  alias Oskol.Repo
  alias Oskol.Reviews

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp a_room do
    id = "rb" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))

    Repo.insert!(%Oskol.Persistence.Game{
      id: id,
      slug: "backgammon",
      config: %{"format" => "unlimited"},
      seed: 7,
      players: [],
      status: "finished"
    })

    id
  end

  test "an empty review is found and a full one is not" do
    emptied = a_room()
    fine = a_room()

    Reviews.save(emptied, 1, "done", 1, %{"turns" => []}, nil, %{"turns" => []}, 0)
    Reviews.save(fine, 1, "done", 1, %{"turns" => [%{}]}, nil, %{"turns" => [%{}]}, 41)

    found = Reviews.empty(100)
    ids = Enum.map(found, & &1.game_id)

    assert emptied in ids
    refute fine in ids
  end

  test "a pending or failed review is not one of these: they are already owed or retryable" do
    pending = a_room()
    failed = a_room()

    Reviews.save(pending, 1, "pending", 0, nil, nil, nil, nil)
    Reviews.save(failed, 1, "failed", 3, nil, "the engine gave up", nil, 0)

    ids = Reviews.empty(100) |> Enum.map(& &1.game_id)

    refute pending in ids
    refute failed in ids
  end

  test "one room can be asked about on its own" do
    mine = a_room()
    theirs = a_room()

    Reviews.save(mine, 1, "done", 1, %{}, nil, %{}, 0)
    Reviews.save(theirs, 1, "done", 1, %{}, nil, %{}, 0)

    assert [%{game_id: ^mine}] = Reviews.empty(100, mine)
  end

  test "rebuilding puts the game back to pending and marks its room owed" do
    room = a_room()
    Reviews.save(room, 1, "done", 3, %{"turns" => []}, nil, %{"turns" => []}, 0)

    assert :ok = Reviews.rebuild(room, 1)

    row = Repo.get_by!(Reviews.Review, game_id: room, game_number: 1)
    assert row.status == "pending"
    # A full set of tries, and the wrong answer gone with the status: what is
    # stored is what a retry leaves.
    assert row.attempts == 0
    assert row.response == nil
    assert row.report == nil

    # And the queue has something to find.
    assert Reviews.analysis_owed_at(room) != nil
  end

  test "a rebuilt review is no longer listed, so the sweep is safe to run twice" do
    room = a_room()
    Reviews.save(room, 1, "done", 1, %{}, nil, %{}, 0)

    assert [_] = Reviews.empty(100, room)
    Reviews.rebuild(room, 1)
    assert [] = Reviews.empty(100, room)
  end

  test "the release twin says what it would do and, dry, does none of it" do
    room = a_room()
    Reviews.save(room, 1, "done", 1, %{}, nil, %{}, 0)

    said = fn _line -> :ok end
    assert %{found: 1, queued: 0} = Oskol.Release.rebuild_reviews(room: room, say: said)

    row = Repo.get_by!(Reviews.Review, game_id: room, game_number: 1)
    assert row.status == "done"

    assert %{found: 1, queued: 1} =
             Oskol.Release.rebuild_reviews(room: room, dry_run: false, say: said)

    row = Repo.get_by!(Reviews.Review, game_id: room, game_number: 1)
    assert row.status == "pending"
  end
end
