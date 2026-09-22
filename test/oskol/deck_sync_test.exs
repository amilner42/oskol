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
          evaluated_by: %{"levels" => %{}}
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

    :ok = Puzzles.store(game_id, 1, puzzles, sources)
  end

  defp ids_for(game_id, player_id) do
    base =
      :crypto.hash(:sha256, game_id <> player_id)
      |> Base.encode32(padding: false)
      |> binary_part(0, 7)

    for n <- 1..4, do: base <> Integer.to_string(n)
  end

  defp sources_of(game_id) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id, order_by: s.turn) |> Repo.all()
  end

  defp cards(user_id) do
    {:ok, %{reviews: _, new: new}} = Retain.queue(user_id, limit: 50)
    Enum.map(new, & &1.key)
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

    test "a game with no mistakes gives its owner nothing" do
      user = an_account("arie@oskol.test")
      game_id = a_room([seat("p1", guest: "g1", user: user.id)])
      :ok = Puzzles.store(game_id, 1, [], [])

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

      # The persister answers `:pending` when the caller's call times out;
      # the handler runs to the end regardless, which is the whole reason
      # the deck is asked for from there and not from the request.
      fresh = "guest-after-timeout"

      task =
        Task.async(fn ->
          Oskol.Game.Persister.stamp_seats(guest, fresh, user.id)
        end)

      assert {:ok, {1, [^game_id]}} = Task.await(task, 5_000)

      :ok = Oskol.Reviews.Queue.await_idle()
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

    test "a browser with no games has nothing to practise" do
      assert Puzzles.guest_sources("nobody-at-all") == []
      assert Puzzles.guest_sources("") == []
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
