defmodule Oskol.PracticeTest do
  @moduledoc """
  The `practice` capability against the real database: the Gleam tuples in,
  the Gleam tuples out, and the rows the `retain` library keeps in between.

  What a deck *decides* is tested on stubs
  (test/oskol/practice_handler_test.gleam). This is the other half: that the
  Elixir twin and its Gleam record agree on tag and field order, that the
  types cross correctly (times as Unix milliseconds, content as JSON text,
  tags sorted), and that the library underneath does what the cap claims --
  including the one invariant everything rests on, that replaying the log
  reproduces the live state.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oskol.Gleam.Caps.Practice
  alias Oskol.Repo

  # The cap is a Gleam record: a tagged tuple whose field order is the
  # contract with src/oskol/caps/practice.gleam. Destructuring it here is what
  # makes a field added on one side and not the other a failing test.
  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    {:practice_caps, put_user, put_items, cards, relapse, queue, start, start_new, review, amend,
     defer_until, defer_tomorrow, master, suspend, resume, summary, ladder, days} =
      Practice.build()

    caps = %{
      put_user: put_user,
      put_items: put_items,
      cards: cards,
      relapse: relapse,
      queue: queue,
      start: start,
      start_new: start_new,
      review: review,
      amend: amend,
      defer_until: defer_until,
      defer_tomorrow: defer_tomorrow,
      master: master,
      suspend: suspend,
      resume: resume,
      summary: summary,
      ladder: ladder,
      days: days
    }

    uid = "acct-#{System.unique_integer([:positive])}"
    {:ok, nil} = caps.put_user.(uid, "America/Vancouver", 10)

    {:ok, caps: caps, uid: uid}
  end

  defp item(key, tags \\ [], content \\ %{}, position \\ :none) do
    {:item, key, tags, Jason.encode!(content), position}
  end

  defp ask(opts \\ []) do
    {:ask, Keyword.get(opts, :tags, []), Keyword.get(opts, :limit, 20),
     Keyword.get(opts, :offset, 0), Keyword.get(opts, :new_after_reviews, true),
     Keyword.get(opts, :new_limit, :none)}
  end

  defp keys(cards), do: Enum.map(cards, fn {:card, key, _, _, _, _, _, _, _} -> key end)

  test "the ladder counts every card by level, and an empty deck is eight zeroes",
       %{caps: caps, uid: uid} do
    assert caps.ladder.(uid) == [0, 0, 0, 0, 0, 0, 0, 0]

    {:ok, 3} = caps.put_items.(uid, [item("a"), item("b"), item("c")])
    # Three new cards: all on the bottom rung, and the bars add up to the
    # deck size printed beside them.
    assert caps.ladder.(uid) == [3, 0, 0, 0, 0, 0, 0, 0]
    assert [{:summary, _, 3, _, _, _, _, _}] = caps.summary.(uid, [])

    # One answered right climbs a rung; a card at the top jumps to the end.
    assert 3 = caps.start.(uid, ["a", "b", "c"])
    {:ok, _} = caps.review.(uid, "a", :pass)
    assert caps.ladder.(uid) == [2, 1, 0, 0, 0, 0, 0, 0]

    assert 1 = caps.master.(uid, ["b"])
    assert caps.ladder.(uid) == [1, 1, 0, 0, 0, 0, 0, 1]

    # A paused card is still in the deck, so it is still on the ladder.
    assert 1 = caps.suspend.(uid, ["c"])
    assert caps.ladder.(uid) == [1, 1, 0, 0, 0, 0, 0, 1]

    # Another account's deck is not this one's.
    other = "acct-#{System.unique_integer([:positive])}"
    {:ok, nil} = caps.put_user.(other, "America/Vancouver", 10)
    assert caps.ladder.(other) == [0, 0, 0, 0, 0, 0, 0, 0]
  end

  test "the day strip marks the days this deck was practised on", %{caps: caps, uid: uid} do
    # A deck with nothing in it has practised on none of them, and the
    # strip is still as long as it was asked for.
    assert caps.days.(uid, 30) == List.duplicate(false, 30)
    assert length(caps.days.(uid, 7)) == 7

    {:ok, 2} = caps.put_items.(uid, [item("a"), item("b")])
    assert 2 = caps.start.(uid, ["a", "b"])
    {:ok, _} = caps.review.(uid, "a", :pass)

    strip = caps.days.(uid, 30)
    assert length(strip) == 30
    # Oldest first, ending today: today is the last mark.
    assert List.last(strip) == true
    assert Enum.count(strip, & &1) == 1

    # Putting a card off is not practice.
    other = "acct-#{System.unique_integer([:positive])}"
    {:ok, nil} = caps.put_user.(other, "America/Vancouver", 10)
    {:ok, 1} = caps.put_items.(other, [item("c")])
    assert 1 = caps.start.(other, ["c"])
    {:ok, _} = caps.defer_tomorrow.(other, "c")
    assert Enum.count(caps.days.(other, 30), & &1) == 0
  end

  test "put_user opens a deck and is idempotent", %{caps: caps, uid: uid} do
    # The setup already called it once; calling it again is what every
    # session does, and it must not fail or duplicate.
    assert caps.put_user.(uid, "America/Vancouver", 10) == {:ok, nil}
    assert {:ok, %Retain.User{tz: "America/Vancouver", new_per_day: 10}} = Retain.fetch_user(uid)
    assert Repo.aggregate(from(u in Retain.User, where: u.uid == ^uid), :count) == 1

    # An empty timezone falls back rather than raising: a deck is opened
    # before anyone has told us where the player is.
    other = "acct-#{System.unique_integer([:positive])}"
    assert caps.put_user.(other, "", 10) == {:ok, nil}
    assert {:ok, %Retain.User{tz: tz}} = Retain.fetch_user(other)
    assert tz == Practice.default_tz()
  end

  test "put_items adds cards once, and content survives the round trip", %{
    caps: caps,
    uid: uid
  } do
    content = %{"xgid" => "XGID=aB--", "dice" => [6, 4], "nested" => %{"n" => 1}}

    items = [
      item("pos:a/move", [{"kind", "move"}, {"game", "7"}], content, {:some, 1}),
      item("pos:b/cube", [{"kind", "cube"}], %{}, {:some, 2})
    ]

    assert caps.put_items.(uid, items) == {:ok, 2}

    # Re-adding the same game's mistakes is safe: nothing is new.
    assert caps.put_items.(uid, items) == {:ok, 0}
    assert caps.put_items.(uid, items ++ [item("pos:c/move")]) == {:ok, 1}

    {:ok, stored} = Retain.fetch_item(uid, "pos:a/move")
    assert stored.content == content
    assert stored.tags == %{"kind" => "move", "game" => "7"}
    assert stored.position == 1
  end

  test "a queue hands back due cards then new ones, with times in milliseconds", %{
    caps: caps,
    uid: uid
  } do
    {:ok, 2} = caps.put_items.(uid, [item("pos:a"), item("pos:b")])

    # Nothing is in rotation yet, so everything arrives as new material.
    assert {:session, [], fresh, 10} = caps.queue.(uid, ask())
    assert keys(fresh) == ["pos:a", "pos:b"]

    assert [{:card, "pos:a", [], "{}", 0, due_ms, 0, 0, :new} | _] = fresh
    assert is_integer(due_ms)
    assert abs(due_ms - System.system_time(:millisecond)) < 60_000

    # Answering a new card starts it; it is then a review, not new.
    {:ok, _} = caps.review.(uid, "pos:a", :pass)
    assert {:session, reviews, _, _} = caps.queue.(uid, ask(new_limit: {:some, 0}))
    assert keys(reviews) == []

    # ...due tomorrow, because level 0 and level 1 are both one day here.
    {:ok, card} = Retain.fetch_item(uid, "pos:a")
    assert card.level == 1
    assert_in_delta DateTime.diff(card.due, DateTime.utc_now(), :second), 86_400, 60
  end

  test "a card due later today is neither queued nor counted as due", %{caps: caps, uid: uid} do
    {:ok, 1} = caps.put_items.(uid, [item("later")])
    assert caps.start.(uid, ["later"]) == 1

    due_later = DateTime.add(DateTime.utc_now(), 60 * 60, :second)
    due_later_ms = DateTime.to_unix(due_later, :millisecond)

    assert {:ok, {:graded, 0, 0, ^due_later_ms, _}} =
             caps.defer_until.(uid, "later", due_later_ms)

    assert {:session, [], [], _} = caps.queue.(uid, ask())
    assert [{:summary, [], 1, 0, 1, 0, 0, +0.0}] = caps.summary.(uid, [])
  end

  test "a deck cannot be opened with a timezone that is not one, and says so", %{caps: caps} do
    other = "acct-#{System.unique_integer([:positive])}"
    assert {:error, :unknown_timezone} = caps.put_user.(other, "Mars/Olympus", 10)
    assert Retain.fetch_user(other) == {:error, :not_found}
  end

  test "a card whose content is not a JSON object is refused, and nothing is written", %{
    caps: caps,
    uid: uid
  } do
    # Neither of these can come from a puzzle page; the cap is the boundary anyway.
    assert {:error, :bad_content} = caps.put_items.(uid, [{:item, "a", [], "[1,2]", :none}])
    assert {:error, :bad_content} = caps.put_items.(uid, [{:item, "a", [], "\"nope\"", :none}])
    assert {:error, :bad_content} = caps.put_items.(uid, [{:item, "a", [], "not json", :none}])

    # Not even the valid card that came with the bad one.
    assert {:error, :bad_content} =
             caps.put_items.(uid, [item("good"), {:item, "bad", [], "[]", :none}])

    assert Retain.fetch_item(uid, "good") == {:error, :not_found}
  end

  test "the configured ladder is the brief's, not retain's default" do
    assert Application.get_env(:retain, :intervals) == [1, 1, 3, 7, 21, 58, 145, 365]

    # The one that matters: a miss comes back tomorrow, never later today.
    assert Retain.Ladder.interval_days(Retain.Ladder.default(), 0) == 1
  end

  test "an offset walks further down the due list", %{caps: caps, uid: uid} do
    keys = Enum.map(1..6, &"pos:#{&1}")
    {:ok, 6} = caps.put_items.(uid, Enum.map(keys, &item/1))
    assert caps.start.(uid, keys) == 6

    assert {:session, first, _, _} = caps.queue.(uid, ask(limit: 4))
    assert {:session, second, _, _} = caps.queue.(uid, ask(limit: 4, offset: 4))

    assert length(first) == 4
    assert length(second) == 2
    assert Enum.sort(keys(first) ++ keys(second)) == Enum.sort(keys)
  end

  test "new material is held back until nothing is due", %{caps: caps, uid: uid} do
    {:ok, 2} = caps.put_items.(uid, [item("due:1"), item("fresh:1")])
    assert caps.start.(uid, ["due:1"]) == 1

    assert {:session, reviews, [], _} = caps.queue.(uid, ask(new_after_reviews: true))
    assert keys(reviews) == ["due:1"]

    # Asked the other way, both come at once.
    assert {:session, _, fresh, _} = caps.queue.(uid, ask(new_after_reviews: false))
    assert keys(fresh) == ["fresh:1"]
  end

  test "tags filter the queue and group the summary", %{caps: caps, uid: uid} do
    {:ok, 4} =
      caps.put_items.(uid, [
        item("a", [{"kind", "cube"}]),
        item("b", [{"kind", "cube"}]),
        item("c", [{"kind", "move"}]),
        item("d", [{"kind", "move"}])
      ])

    assert {:session, _, fresh, _} = caps.queue.(uid, ask(tags: [{"kind", "cube"}]))
    assert keys(fresh) == ["a", "b"]

    # Groups cross sorted by tag key, with one row per distinct value.
    assert [
             {:summary, [{"kind", "cube"}], 2, 2, 0, 0, 0, +0.0},
             {:summary, [{"kind", "move"}], 2, 2, 0, 0, 0, +0.0}
           ] = caps.summary.(uid, ["kind"])

    assert [{:summary, [], 4, 4, 0, 0, 0, +0.0}] = caps.summary.(uid, [])
  end

  test "review grades a card and amend corrects it, with the log agreeing", %{
    caps: caps,
    uid: uid
  } do
    {:ok, 1} = caps.put_items.(uid, [item("pos:a")])

    assert {:ok, {:graded, 0, 1, due_ms, review_id}} = caps.review.(uid, "pos:a", :pass)
    assert is_integer(review_id)
    assert is_integer(due_ms)

    # The player says on the reveal that it was really a miss.
    assert {:ok, {:graded, 1, 0, _, amendment}} = caps.amend.(uid, "pos:a", review_id, :again)
    assert amendment != review_id

    {:ok, card} = Retain.fetch_item(uid, "pos:a")
    assert card.level == 0
    assert card.lapses == 1
    # Append-only: the row it corrected is still there.
    assert %Retain.Review{outcome: :pass} = Repo.get!(Retain.Review, review_id)
    assert reviews(uid) == 2
  end

  test ":again drops to the bottom, :fail only one step", %{caps: caps, uid: uid} do
    {:ok, 1} = caps.put_items.(uid, [item("pos:a")])
    for _ <- 1..4, do: {:ok, _} = caps.review.(uid, "pos:a", :pass)
    assert {:ok, %Retain.Item{level: 4}} = Retain.fetch_item(uid, "pos:a")

    assert {:ok, {:graded, 4, 3, _, _}} = caps.review.(uid, "pos:a", :fail)
    assert {:ok, {:graded, 3, 0, _, _}} = caps.review.(uid, "pos:a", :again)
  end

  test "a card not yet in rotation cannot be snoozed, and starting it stays honest", %{
    caps: caps,
    uid: uid
  } do
    {:ok, 1} = caps.put_items.(uid, [item("fresh")])
    until_ms = System.system_time(:millisecond) + 5 * 24 * 60 * 60 * 1000

    # A defer on a new card would move a date nothing reads, and `start` would write over it
    # with no log row -- which is exactly how live state and a rebuild came to disagree.
    assert {:error, :card_not_started} = caps.defer_until.(uid, "fresh", until_ms)

    assert caps.start.(uid, ["fresh"]) == 1
    live = snapshot(uid, ["fresh"])

    assert {:ok, _} = Retain.rebuild(uid)
    assert snapshot(uid, ["fresh"]) == live

    # Started, it snoozes like anything else, and that still round-trips.
    assert {:ok, {:graded, 0, 0, ^until_ms, _}} = caps.defer_until.(uid, "fresh", until_ms)
    deferred = snapshot(uid, ["fresh"])
    assert {:ok, _} = Retain.rebuild(uid)
    assert snapshot(uid, ["fresh"]) == deferred
  end

  test "defer moves the due date and leaves the ladder alone", %{caps: caps, uid: uid} do
    {:ok, 1} = caps.put_items.(uid, [item("pos:a")])
    {:ok, _} = caps.review.(uid, "pos:a", :pass)
    {:ok, before} = Retain.fetch_item(uid, "pos:a")

    until_ms = System.system_time(:millisecond) + 7 * 24 * 60 * 60 * 1000
    assert {:ok, {:graded, 1, 1, ^until_ms, _}} = caps.defer_until.(uid, "pos:a", until_ms)

    {:ok, after_} = Retain.fetch_item(uid, "pos:a")
    assert DateTime.to_unix(after_.due, :millisecond) == until_ms
    assert after_.level == before.level
    assert after_.reps == before.reps
    assert after_.last_reviewed_at == before.last_reviewed_at
  end

  test "master, suspend and resume move cards in and out of rotation", %{
    caps: caps,
    uid: uid
  } do
    {:ok, 3} = caps.put_items.(uid, [item("a"), item("b"), item("c")])

    assert caps.master.(uid, ["a", "b"]) == 2
    assert {:ok, %Retain.Item{level: 7}} = Retain.fetch_item(uid, "a")

    assert caps.suspend.(uid, ["a"]) == 1
    assert {:ok, %Retain.Item{suspended: true}} = Retain.fetch_item(uid, "a")
    # Suspending again moves nothing.
    assert caps.suspend.(uid, ["a"]) == 0

    # A paused card is out of the queue and cannot be answered.
    assert {:session, reviews, _, _} = caps.queue.(uid, ask())
    refute "a" in keys(reviews)
    assert {:error, :card_suspended} = caps.review.(uid, "a", :pass)

    assert caps.resume.(uid, ["a"]) == 1
    assert {:ok, %Retain.Item{suspended: false, level: 7}} = Retain.fetch_item(uid, "a")
  end

  test "the refusals a player can be given each cross as themselves", %{
    caps: caps,
    uid: uid
  } do
    {:ok, 1} = caps.put_items.(uid, [item("pos:a")])

    assert {:error, :unknown_card} = caps.review.(uid, "nope", :pass)
    assert {:error, :unknown_card} = caps.defer_until.(uid, "nope", 0)

    {:ok, {:graded, _, _, _, id}} = caps.review.(uid, "pos:a", :pass)

    # A defer is not an attempt, so there is nothing in it to correct.
    {:ok, {:graded, _, _, _, deferred}} =
      caps.defer_until.(uid, "pos:a", System.system_time(:millisecond) + 86_400_000)

    assert {:error, :not_amendable} = caps.amend.(uid, "pos:a", deferred, :pass)
    assert {:error, :unknown_card} = caps.amend.(uid, "pos:a", id + 10_000, :pass)

    1 = caps.suspend.(uid, ["pos:a"])
    assert {:error, :card_suspended} = caps.amend.(uid, "pos:a", id, :fail)
  end

  test "a rebuild of the log reproduces every card the cap wrote", %{caps: caps, uid: uid} do
    keys = Enum.map(1..5, &"pos:#{&1}")
    {:ok, 5} = caps.put_items.(uid, Enum.map(keys, &item/1))

    # A session's worth of everything the cap can write.
    for {key, outcome} <- Enum.zip(keys, [:pass, :partial, :fail, :again, :known]) do
      {:ok, _} = caps.review.(uid, key, outcome)
    end

    {:ok, {:graded, _, _, _, id}} = caps.review.(uid, "pos:1", :pass)
    {:ok, _} = caps.amend.(uid, "pos:1", id, :again)
    {:ok, _} = caps.defer_until.(uid, "pos:2", System.system_time(:millisecond) + 86_400_000)
    1 = caps.master.(uid, ["pos:3"])

    live = snapshot(uid, keys)

    # Scribble over the derived fields, so a rebuild that did nothing is caught.
    Repo.update_all(
      from(i in Retain.Item, join: u in assoc(i, :user), where: u.uid == ^uid),
      set: [level: 6, reps: 99, lapses: 99]
    )

    assert {:ok, %{items: 5}} = Retain.rebuild(uid)
    assert snapshot(uid, keys) == live
  end

  defp reviews(uid) do
    Repo.aggregate(
      from(r in Retain.Review,
        join: i in assoc(r, :item),
        join: u in assoc(i, :user),
        where: u.uid == ^uid
      ),
      :count
    )
  end

  defp snapshot(uid, keys) do
    Map.new(keys, fn key ->
      {:ok, item} = Retain.fetch_item(uid, key)
      {key, Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])}
    end)
  end
end
