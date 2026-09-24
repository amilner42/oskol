defmodule Oskol.DeckSyncTest do
  @moduledoc """
  Filling the mistakes deck against the real rows.

  The rules -- whose mistakes, in what order, what is stamped -- are decided
  and tested in Gleam (test/oskol/deck_sync_test.gleam). What is under test
  here is everything that only the database can answer: that the queries
  find an owned seat and nothing else, that a sign-in's stamp is followed by
  a sync even when the browser that asked has gone, that a sweep gives up
  after three tries, and that the mix task's dry run writes nothing at all.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oskol.Auth
  alias Oskol.Persistence
  alias Oskol.Practice
  alias Oskol.Puzzles
  alias Oskol.Repo

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  # ---------- A room with one mistake on each seat ----------

  defp an_account(email), do: Auth.find_or_create_user(email)

  defp a_guest(id) do
    Oskol.Guests.touch(id)
    id
  end

  defp a_room(players) do
    id = "d-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    Repo.insert!(%Persistence.Game{
      id: id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: players,
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    :ok = Oskol.Reviews.save(id, 1, "done", 1, %{"turns" => []}, nil, %{"turns" => []}, 3)
    id
  end

  defp seat(id, opts) do
    %{"id" => id, "name" => Keyword.get(opts, :name, id)}
    |> maybe_put("guest_id", Keyword.get(opts, :guest))
    |> maybe_put("user_id", Keyword.get(opts, :user))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # One mistake per named seat, written the way the review job writes them.
  defp mistakes(game_id, player_ids) do
    key_of = fn player_id -> "k-#{game_id}-#{player_id}" end

    puzzles =
      for player_id <- player_ids do
        %{
          key: key_of.(player_id),
          ids: ids_for(game_id, player_id),
          kind: "move",
          question: %{
            "version" => 1,
            "kind" => "move",
            "board" => List.duplicate(0, 26),
            "dice" => [6, 4],
            "cube" => %{"value" => 1, "owner" => "center"},
            "score" => nil,
            "crawford" => false,
            "jacoby" => false
          },
          answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
          evaluated_by: %{"levels" => %{}},
          complete: true
        }
      end

    sources =
      for {player_id, turn} <- Enum.with_index(player_ids, 1) do
        %{
          key: key_of.(player_id),
          game_number: 1,
          turn: turn,
          kind: "move",
          seat: turn - 1,
          player_id: player_id,
          played: "13/8 13/11",
          equity_lost: 0.061,
          grade: "bad",
          skipped_reason: nil
        }
      end

    {:ok, _} = Puzzles.store(game_id, 1, puzzles, sources)
  end

  # The same position, reached again in another game: one puzzle, a second
  # source.
  defp same_mistake(game_id, first_game) do
    [%{puzzle_id: puzzle_id} | _] = sources_of(first_game)
    puzzle = Repo.get(Puzzles.Puzzle, puzzle_id)

    # The puzzle goes in again with the same key: `store/4` keeps the row
    # that is already there and hands its id back, which is how the second
    # game's source points at the first game's puzzle.
    {:ok, _} =
      Puzzles.store(
        game_id,
        1,
        [
          %{
            key: puzzle.key,
            ids: [puzzle.id],
            kind: puzzle.kind,
            question: puzzle.question,
            answer: puzzle.answer,
            evaluated_by: puzzle.evaluated_by,
            complete: true
          }
        ],
        [
          %{
            key: puzzle.key,
            game_number: 1,
            turn: 1,
            kind: "move",
            seat: 0,
            player_id: "p1",
            played: "13/8 13/11",
            equity_lost: 0.061,
            grade: "bad",
            skipped_reason: nil
          }
        ]
      )
  end

  defp ids_for(game_id, player_id) do
    base =
      :crypto.hash(:sha256, game_id <> player_id)
      |> Base.encode32(padding: false)
      |> binary_part(0, 7)

    for n <- 1..4, do: base <> Integer.to_string(n)
  end

  # Move a room's review row back in time: when its game was played, which
  # is what the deck orders on.
  defp backdate(game_id, amount, unit) do
    when_ = DateTime.add(DateTime.utc_now(), amount, unit)

    from(r in Oskol.Reviews.Review, where: r.game_id == ^game_id)
    |> Repo.update_all(set: [inserted_at: when_])
  end

  defp sources_of(game_id) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id, order_by: s.turn) |> Repo.all()
  end

  defp cards(user_id) do
    {:ok, %{new: new}} = Retain.queue(user_id, limit: 50)
    Enum.map(new, & &1.key)
  end

  # A session exactly as the handler asks for one: the front of the queue,
  # due before new, twenty at a time.
  defp session(user_id) do
    {:ok, %{reviews: reviews, new: new}} =
      Retain.queue(user_id, limit: 20, new: :after_reviews)

    Enum.map(reviews ++ new, & &1.key)
  end

  defp answer_all(user_id, keys) do
    Enum.each(keys, fn key ->
      {:ok, _} = Retain.start(user_id, [key])
      {:ok, _} = Retain.review(user_id, key, :pass)
    end)
  end

  # ---------- Whose mistakes go in ----------

  describe "sync/2" do
    test "gives an account the mistakes on the seat it owns, and no others" do
      user = an_account("arie@oskol.test")
      other = an_account("charlie@oskol.test")

      game_id =
        a_room([
          seat("p1", guest: "g1", user: user.id),
          seat("p2", guest: "g2", user: other.id)
        ])

      mistakes(game_id, ["p1", "p2"])

      assert {:ok, 1} = Practice.sync(user.id)

      [mine] = cards(user.id)
      [source] = Enum.filter(sources_of(game_id), &(&1.player_id == "p1"))
      assert mine == source.puzzle_id
      # The opponent's row is nobody's business of ours and is not stamped.
      assert [theirs] = Enum.filter(sources_of(game_id), &(&1.player_id == "p2"))
      assert is_nil(theirs.deck_synced_at)
      assert source.deck_synced_at != nil
    end

    test "leaves a seat no account owns alone" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1"), seat("p2", guest: "g2")])
      mistakes(game_id, ["p1"])

      assert {:ok, 0} = Practice.sync(user.id)
      assert Enum.all?(sources_of(game_id), &is_nil(&1.deck_synced_at))
      # No deck was opened for an account with nothing owed.
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end

    test "is idempotent: a second run adds nothing and stamps nothing new" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      assert {:ok, 1} = Practice.sync(user.id)
      [first] = sources_of(game_id)

      assert {:ok, 0} = Practice.sync(user.id)
      [again] = sources_of(game_id)
      assert again.deck_synced_at == first.deck_synced_at
      assert again.deck_attempts == first.deck_attempts
      assert length(cards(user.id)) == 1
    end

    test "introduces the newest game first" do
      user = an_account("arie@oskol.test")
      older = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(older, ["p1"])
      newer = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(newer, ["p1"])

      assert {:ok, 2} = Practice.sync(user.id)

      [newest, oldest] = cards(user.id)
      assert newest == hd(sources_of(newer)).puzzle_id
      assert oldest == hd(sources_of(older)).puzzle_id
    end

    test "orders by when the game was played, not when it was extracted" do
      user = an_account("arie@oskol.test")
      older = a_room([seat("p1", guest: "g1", user: user.id)])
      newer = a_room([seat("p1", guest: "g1", user: user.id)])

      # The newer game really is the newer game...
      backdate(older, -3, :day)

      # ...but its mistakes are written down second, which is what a
      # backfill or a retried review looks like.
      mistakes(newer, ["p1"])
      mistakes(older, ["p1"])

      assert {:ok, 2} = Practice.sync(user.id)

      assert cards(user.id) == [
               hd(sources_of(newer)).puzzle_id,
               hd(sources_of(older)).puzzle_id
             ]
    end

    test "drills one game's mistakes in the order they were made" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      # Two seats' worth of rows, both on this account's seat: turns 1 and 2.
      mistakes(game_id, ["p1", "p1b"])
      Repo.update_all(Puzzles.Source, set: [player_id: "p1"])
      :ok = Puzzles.refresh_owners([game_id])

      assert {:ok, 2} = Practice.sync(user.id)

      [first, second] = Enum.sort_by(sources_of(game_id), & &1.turn)
      assert cards(user.id) == [first.puzzle_id, second.puzzle_id]
    end

    test "a game with no mistakes gives its owner nothing" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      {:ok, _} = Puzzles.store(game_id, 1, [], [])

      assert {:ok, 0} = Practice.sync(user.id)
    end

    test "the timezone a browser set is not undone by a later sync" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      {:ok, _} = Retain.put_user(user.id, tz: "America/Vancouver")
      assert {:ok, 1} = Practice.sync(user.id)

      {:ok, deck} = Retain.fetch_user(user.id)
      assert deck.tz == "America/Vancouver"
    end
  end

  # ---------- The sweep, and giving up ----------

  describe "sweep/1" do
    test "finds what nothing else got to, and says whose it is" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      assert [%{user_id: owner, sources: 1, game_ids: [^game_id]}] = Practice.pending()
      assert owner == user.id

      assert %{accounts: 1, added: 1, failed: 0} = Practice.sweep()
      assert Practice.pending() == []
    end

    test "gives up on a row after three tries, with a reason" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      # Three reads is three tries; the fourth finds nothing to offer, so
      # the sweep stops coming back for a row it can never place.
      for _ <- 1..3 do
        assert [_] = Puzzles.owned_sources(user.id, [])
      end

      assert [] = Puzzles.owned_sources(user.id, [])
      assert Practice.pending() == []

      [source] = sources_of(game_id)
      assert source.deck_attempts == 3
      assert is_nil(source.deck_synced_at)

      # And the reason is on the row for an operator to find.
      :ok = Puzzles.sync_failed([source.id], "retain said no")
      assert Repo.reload(source).deck_error == "retain said no"
    end

    test "a row with tries left keeps no reason from a try that failed" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])
      [source] = sources_of(game_id)

      :ok = Puzzles.sync_failed([source.id], "a hiccup")
      assert is_nil(Repo.reload(source).deck_error)

      assert {:ok, 1} = Practice.sync(user.id)
      assert Repo.reload(source).deck_synced_at != nil
    end
  end

  # ---------- Signing in ----------

  describe "the sign-in stamp" do
    setup do
      # The queue is off in tests; the deck cast needs it on, and nothing
      # else in this describe asks it for a room.
      Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: true)
      Oskol.Reviews.Queue.reset()

      on_exit(fn ->
        Application.put_env(:oskol, Oskol.Reviews.Queue, enabled: false)
      end)

      :ok
    end

    test "a browser that signs in finds its games' mistakes in its deck" do
      guest = a_guest("guest-signing-in")
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: guest), seat("p2", guest: "g2")])
      mistakes(game_id, ["p1"])

      # Exactly what the sign-in handler does: the stamp through the
      # persister, which casts the deck job once its transaction commits.
      fresh = "guest-after-signing-in"
      assert {:ok, {1, [^game_id]}} = Oskol.Game.Persister.stamp_seats(guest, fresh, user.id)

      :ok = Oskol.Reviews.Queue.await_idle()
      assert cards(user.id) == [hd(sources_of(game_id)).puzzle_id]
    end

    test "a stamp that commits after the caller gave up still fills the deck" do
      guest = a_guest("guest-timed-out")
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: guest)])
      mistakes(game_id, ["p1"])

      # The caller really does give up: a call that times out before the
      # handler has answered is exactly what `stamp_seats/3` turns into
      # `:pending` in production, and the whole reason the deck is asked
      # for from the handler and not from the request.
      fresh = "guest-after-timeout"

      gave_up =
        try do
          GenServer.call(
            Oskol.Game.Persister,
            {:stamp_seats, guest, fresh, user.id},
            0
          )
        catch
          :exit, {:timeout, _} -> :pending
        end

      assert gave_up == :pending

      # The handler runs to the end regardless: the seats moved and the
      # deck filled, with nobody left waiting for either.
      :ok = Oskol.Game.Persister.flush()
      :ok = Oskol.Reviews.Queue.await_idle()

      assert [%{"user_id" => owner}] = Repo.reload(%Persistence.Game{id: game_id}).players
      assert owner == user.id
      assert cards(user.id) == [hd(sources_of(game_id)).puzzle_id]
    end

    test "a sign-in that stamps nothing asks for no deck work" do
      user = an_account("arie@oskol.test")
      a_guest("guest-with-no-seats")

      assert {:ok, {0, []}} =
               Oskol.Game.Persister.stamp_seats("guest-with-no-seats", "fresh", user.id)

      :ok = Oskol.Reviews.Queue.await_idle()
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end
  end

  # ---------- A guest's own mistakes ----------

  describe "guest_sources/1" do
    test "answers the mistakes on the seats a cookie holds, newest first" do
      guest = a_guest("guest-with-games")
      older = a_room([seat("p1", guest: guest), seat("p2", guest: "g2")])
      mistakes(older, ["p1", "p2"])
      newer = a_room([seat("p1", guest: guest)])
      mistakes(newer, ["p1"])

      rows = Puzzles.guest_sources(guest)

      assert Enum.map(rows, & &1.puzzle_id) == [
               hd(sources_of(newer)).puzzle_id,
               hd(sources_of(older)).puzzle_id
             ]

      assert Enum.all?(rows, &(&1.player_id == "p1"))
      # A guest's list writes nothing at all: no try is charged.
      assert Enum.all?(sources_of(newer), &(&1.deck_attempts == 0))
    end

    test "never offers a seat an account owns" do
      user = an_account("arie@oskol.test")
      guest = a_guest("guest-who-signed-in")
      game_id = a_room([seat("p1", guest: guest, user: user.id)])
      mistakes(game_id, ["p1"])

      assert Puzzles.guest_sources(guest) == []
    end

    test "a browser with no games has nothing to practice" do
      assert Puzzles.guest_sources("nobody-at-all") == []
      assert Puzzles.guest_sources("") == []
    end
  end

  # ---------- When the deck itself is away ----------

  describe "a deck that cannot be reached" do
    # The realistic failure, and the one that used to lose mistakes
    # silently: not retain refusing, but retain raising. The rows were
    # charged for the try and nothing was written down about why.
    defp with_broken_deck(fun) do
      was = Application.get_env(:retain, :repo)
      Application.put_env(:retain, :repo, Oskol.NoSuchRepoAtAll)

      try do
        fun.()
      after
        Application.put_env(:retain, :repo, was)
      end
    end

    test "records why on the row, and --reset lets it be tried again" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      with_broken_deck(fn ->
        for _ <- 1..3, do: assert(:error = Practice.sync(user.id))
      end)

      [source] = sources_of(game_id)
      assert source.deck_attempts == 3
      assert is_nil(source.deck_synced_at)
      # Not silence: the row says what went wrong, and an operator can find
      # it. Without this the mistake is gone for good with no trace.
      assert source.deck_error =~ "NoSuchRepoAtAll"

      # Out of tries, so no sweep offers it any more...
      assert Practice.pending() == []

      # ...until the operator, having fixed the cause, reopens it.
      assert Practice.reset() == 1
      assert [%{user_id: _}] = Practice.pending()
      assert {:ok, 1} = Practice.sync(user.id)

      reopened = Repo.reload(source)
      assert reopened.deck_synced_at != nil
      # And a row that syncs does not keep yesterday's complaint.
      assert is_nil(reopened.deck_error)
    end
  end

  # ---------- A session, against the real ladder ----------

  describe "a session over real retain" do
    test "21 due and 10 new: the session finishes all 31, a page at a time" do
      user = an_account("arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC")

      keys = for n <- 1..31, do: "k#{String.pad_leading("#{n}", 2, "0")}"
      {:ok, _} = Retain.put_items(user.id, for(k <- keys, do: %{key: k, tags: %{}, content: %{}}))

      # 21 of them are in rotation and due; the other 10 have never been
      # shown.
      # Started yesterday: a card put into rotation today counts against
      # today's ten new, and this session is about what is *due*.
      yesterday = DateTime.add(DateTime.utc_now(), -1, :day)
      {due, _fresh} = Enum.split(keys, 21)
      {:ok, _} = Retain.start(user.id, due, now: yesterday)

      first = session(user.id)
      assert length(first) == 20

      # The player answers the page. Each one leaves the due set, which is
      # exactly what an offset would have skipped over.
      answer_all(user.id, first)

      second = session(user.id)
      # The 21st, and it alone: the day's new cards wait until nothing is
      # due, which is the brief's rule and retain's `new: :after_reviews`.
      assert length(second) == 1
      assert second != first
      answer_all(user.id, second)

      third = session(user.id)
      assert length(third) == 10
      assert Enum.sort(first ++ second ++ third) == Enum.sort(keys)

      # And only when there is nothing left does a fetch come back empty,
      # which is the one thing "Done for today" waits on.
      answer_all(user.id, third)
      assert session(user.id) == []
    end

    test "KEEP GOING puts ten more in front of the player, over the day's budget" do
      user = an_account("arie@oskol.test")
      {:ok, _} = Retain.put_user(user.id, tz: "Etc/UTC", new_per_day: 10)

      keys = for n <- 1..30, do: "k#{String.pad_leading("#{n}", 2, "0")}"
      {:ok, _} = Retain.put_items(user.id, for(k <- keys, do: %{key: k, tags: %{}, content: %{}}))

      today = session(user.id)
      assert length(today) == 10
      answer_all(user.id, today)

      # The day's budget is spent, so an ordinary fetch is empty...
      assert session(user.id) == []

      # ...and KEEP GOING is what gets past that.
      {:practice_caps, _, _, _, _, _, _, start_new, _, _, _, _, _, _, _, _, _, _, _, _} =
        Oskol.Gleam.Caps.Practice.build()

      assert start_new.(user.id, 10) == 10
      more = session(user.id)
      assert length(more) == 10
      assert Enum.all?(more, &(&1 not in today))
    end
  end

  # ---------- Putting the queue back in order ----------

  describe "mix oskol.puzzles.reposition" do
    test "puts the worst mistakes first, writes nothing on a dry run, and is a no-op twice" do
      user = an_account("arie@oskol.test")

      # A very bad move from a year ago, and a dubious one from today.
      old_game = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(old_game, ["p1"])
      backdate(old_game, -365, :day)
      grade(old_game, "very_bad")

      new_game = a_room([seat("p1", guest: "g2", user: user.id)])
      mistakes(new_game, ["p1"])
      grade(new_game, "doubtful")

      assert {:ok, 2} = Practice.sync(user.id)
      [worst] = Enum.map(sources_of(old_game), & &1.puzzle_id)
      [lesser] = Enum.map(sources_of(new_game), & &1.puzzle_id)

      # Today's rule wrote them, so there is nothing to move.
      assert Practice.reposition(100, false).moved == 0
      assert cards(user.id) == [worst, lesser]

      # A deck written under the old rule: newest game first, whatever the
      # mistake was. The dubious one from today jumps the very bad one.
      from(i in Retain.Item, where: i.key == ^worst) |> Repo.update_all(set: [position: 0])
      from(i in Retain.Item, where: i.key == ^lesser) |> Repo.update_all(set: [position: -1])
      assert cards(user.id) == [lesser, worst]

      dry = Practice.reposition(100, false)
      assert %{accounts: 1, cards: 2, moved: 2} = dry
      # A dry run changes nothing at all.
      assert cards(user.id) == [lesser, worst]

      assert %{moved: 2} = Practice.reposition(100, true)
      assert cards(user.id) == [worst, lesser]

      # Twice is a no-op: a card already in its place is left alone.
      assert %{moved: 0} = Practice.reposition(100, true)
      assert cards(user.id) == [worst, lesser]
    end

    test "a card in rotation keeps its level, its due date and its log" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])
      assert {:ok, 1} = Practice.sync(user.id)
      [key] = Enum.map(sources_of(game_id), & &1.puzzle_id)

      {:ok, _} = Retain.start(user.id, [key])
      {:ok, %{level_after: level}} = Retain.review(user.id, key, :pass)
      before = Repo.one(from(i in Retain.Item, where: i.key == ^key))

      from(i in Retain.Item, where: i.key == ^key) |> Repo.update_all(set: [position: 0])
      assert %{moved: 1} = Practice.reposition(100, true)

      after_ = Repo.one(from(i in Retain.Item, where: i.key == ^key))
      assert after_.level == level
      assert after_.due == before.due
      assert after_.reps == before.reps
      # The only thing that moved is where a new card would be introduced.
      assert after_.position == before.position
    end
  end

  describe "the deck counted by severity" do
    test "a mistake counts in its worst band, and patched is the fourth rung" do
      user = an_account("arie@oskol.test")

      very_bad = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(very_bad, ["p1"])
      grade(very_bad, "very_bad")

      dubious = a_room([seat("p1", guest: "g2", user: user.id)])
      mistakes(dubious, ["p1"])
      grade(dubious, "doubtful")

      assert {:ok, 2} = Practice.sync(user.id)
      [worst] = Enum.map(sources_of(very_bad), & &1.puzzle_id)

      {:practice_caps, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, severity} =
        Oskol.Gleam.Caps.Practice.build()

      # Nothing answered yet: every mistake is still to fix.
      assert Enum.sort(severity.(user.id, 4)) ==
               Enum.sort([{:severity, "doubtful", 1, 0}, {:severity, "very_bad", 1, 0}])

      # Three right in a row is not patched...
      {:ok, _} = Retain.start(user.id, [worst])

      Enum.each(1..3, fn _ ->
        {:ok, _} = Retain.review(user.id, worst, :pass)
      end)

      assert {:severity, "very_bad", 1, 0} in severity.(user.id, 4)

      # ...the fourth is.
      {:ok, %{level_after: 4}} = Retain.review(user.id, worst, :pass)
      assert {:severity, "very_bad", 1, 1} in severity.(user.id, 4)

      # The same position reached in two games is one mistake, in the
      # worse of the two bands.
      same = a_room([seat("p1", guest: "g3", user: user.id)])
      same_mistake(same, dubious)
      grade(same, "bad")
      assert {:ok, 0} = Practice.sync(user.id)
      counted = severity.(user.id, 4)
      assert {:severity, "bad", 1, 0} in counted
      assert Enum.all?(counted, fn {:severity, band, _, _} -> band != "doubtful" end)
      assert Enum.sum(Enum.map(counted, fn {:severity, _, total, _} -> total end)) == 2
    end

    test "an account with no deck is counted as nothing, not as an error" do
      user = an_account("arie@oskol.test")

      {:practice_caps, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, severity} =
        Oskol.Gleam.Caps.Practice.build()

      assert severity.(user.id, 4) == []
    end
  end

  defp grade(game_id, grade) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id)
    |> Repo.update_all(set: [grade: grade])
  end

  # ---------- Making the same mistake again ----------

  describe "a mistake made again" do
    setup do
      user = an_account("arie@oskol.test")
      first = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(first, ["p1"])
      assert {:ok, 1} = Practice.sync(user.id)
      key = hd(sources_of(first)).puzzle_id

      # The same position, reached again in a later game.
      later = a_room([seat("p1", guest: "g1", user: user.id)])
      same_mistake(later, first)

      {:ok, user: user, key: key, later: later}
    end

    test "comes back to the front when the card is in rotation", ctx do
      {:ok, _} = Retain.start(ctx.user.id, [ctx.key])
      {:ok, _} = Retain.review(ctx.user.id, ctx.key, :pass)
      {:ok, before} = Retain.fetch_item(ctx.user.id, ctx.key)
      assert before.level > 0

      # Nothing new to add -- the deck already holds this one -- and that
      # is exactly the point: the player has just made it again.
      assert {:ok, 0} = Practice.sync(ctx.user.id)

      {:ok, item} = Retain.fetch_item(ctx.user.id, ctx.key)
      assert item.level == 0
      assert item.lapses > before.lapses
      # The row is stamped either way: the deck does hold it.
      assert Enum.all?(sources_of(ctx.later), &(&1.deck_synced_at != nil))
    end

    test "leaves a puzzle the player put aside alone", ctx do
      {:ok, _} = Retain.start(ctx.user.id, [ctx.key])
      {:ok, _} = Retain.suspend(ctx.user.id, [ctx.key])

      assert {:ok, 0} = Practice.sync(ctx.user.id)

      {:ok, item} = Retain.fetch_item(ctx.user.id, ctx.key)
      # NEVER means never. A game they happened to play does not undo it.
      assert item.suspended
      assert item.reps == 0
    end

    test "does nothing to a card that has never been shown", ctx do
      {:ok, before} = Retain.fetch_item(ctx.user.id, ctx.key)
      assert is_nil(before.started_at)

      assert {:ok, 0} = Practice.sync(ctx.user.id)

      {:ok, item} = Retain.fetch_item(ctx.user.id, ctx.key)
      # Already at the front of the queue, with nothing to take away.
      assert is_nil(item.started_at)
      assert item.reps == 0
    end
  end

  # ---------- The operator's task ----------

  describe "mix oskol.puzzles.sync" do
    test "a dry run writes nothing: no card, no marker, not one try" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Oskol.Puzzles.Sync.run([]) end)

      assert output =~ user.id
      assert output =~ "1 accounts owed, dry run"

      [source] = sources_of(game_id)
      assert is_nil(source.deck_synced_at)
      assert source.deck_attempts == 0
      assert Retain.fetch_user(user.id) == {:error, :not_found}
    end

    test "--reset reopens the rows that gave up" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])
      [source] = sources_of(game_id)

      Repo.update_all(Puzzles.Source, set: [deck_attempts: 3, deck_error: "something broke"])
      assert Practice.pending() == []

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Oskol.Puzzles.Sync.run(["--reset", "--write"])
        end)

      assert output =~ "1 rows reopened"
      assert output =~ "1 decks filled"
      assert Repo.reload(source).deck_synced_at != nil
    end

    test "--write fills the decks it just listed" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      mistakes(game_id, ["p1"])

      output =
        ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Oskol.Puzzles.Sync.run(["--write"]) end)

      assert output =~ "1 decks filled, 1 new cards, 0 refused"
      assert cards(user.id) == [hd(sources_of(game_id)).puzzle_id]
    end
  end
end
