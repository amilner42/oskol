defmodule Oskol.PuzzlesTest do
  @moduledoc """
  The rows puzzles live in, and the one write that fills them.

  What counts as a puzzle and what its question says is decided and tested
  in Gleam (test/oskol/puzzles_test.gleam). What is under test here is the
  storage contract that ticket leans on: the tables round-trip, the write
  is atomic and idempotent, an id collision resolves, and a failure leaves
  the marker unset so the sweep comes back -- but charged, so it does not
  come back for ever.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oskol.Persistence
  alias Oskol.Puzzles
  alias Oskol.Repo
  alias Oskol.Reviews

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp a_room(opts \\ []) do
    id = "p-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))

    Repo.insert!(%Persistence.Game{
      id: id,
      slug: "backgammon",
      config: %{"format" => "single"},
      seed: 7,
      players: [],
      status: "finished",
      winners: [],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    if Keyword.get(opts, :graded, true) do
      :ok =
        Reviews.save(id, 1, "done", 1, %{"turns" => []}, nil, %{"turns" => []}, 3)
    end

    id
  end

  # Keys and ids unique per test: these tables are global (a puzzle belongs
  # to nobody), so a test asserts about its own rows and never the count of
  # the whole table.
  defp a_key, do: "k-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

  defp some_ids do
    base = :crypto.strong_rand_bytes(4) |> Base.encode16() |> binary_part(0, 7)
    for n <- 1..4, do: base <> Integer.to_string(n)
  end

  defp puzzles_keyed(key) do
    Repo.all(from(p in Puzzles.Puzzle, where: p.key == ^key))
  end

  defp a_puzzle(key, opts \\ []) do
    %{
      key: key,
      ids: Keyword.get(opts, :ids, some_ids()),
      kind: Keyword.get(opts, :kind, "move"),
      question: %{"kind" => "move", "board" => [0, 1, 2], "dice" => [6, 4]},
      answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
      evaluated_by: %{"levels" => %{"moves" => "4ply", "cube" => "4ply"}},
      complete: Keyword.get(opts, :complete, true)
    }
  end

  defp a_source(key, opts \\ []) do
    %{
      key: key,
      game_number: 1,
      turn: Keyword.get(opts, :turn, 4),
      kind: Keyword.get(opts, :kind, "move"),
      seat: 0,
      player_id: "p1",
      played: "13/8 13/11",
      equity_lost: 0.061,
      grade: "bad",
      skipped_reason: Keyword.get(opts, :skipped_reason)
    }
  end

  defp sources_of(game_id) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id, order_by: s.turn) |> Repo.all()
  end

  defp review_row(game_id) do
    Repo.get_by(Reviews.Review, game_id: game_id, game_number: 1)
  end

  describe "store/4" do
    test "writes the puzzles, their sources and the marker together" do
      game_id = a_room()
      key = a_key()
      [first_id | _] = ids = some_ids()

      assert {:ok, _} =
               Puzzles.store(game_id, 1, [a_puzzle(key, ids: ids)], [a_source(key)])

      assert [puzzle] = puzzles_keyed(key)
      assert puzzle.id == first_id
      assert puzzle.key == key
      assert puzzle.question["dice"] == [6, 4]
      assert puzzle.evaluated_by["levels"]["moves"] == "4ply"

      assert [source] = sources_of(game_id)
      assert source.puzzle_id == first_id
      assert source.turn == 4
      assert source.equity_lost == 0.061
      assert source.grade == "bad"
      assert is_nil(source.skipped_reason)

      row = review_row(game_id)
      assert row.puzzles_extracted_at
      assert row.puzzles_attempts == 1
    end

    test "a rerun writes nothing new" do
      game_id = a_room()
      key = a_key()
      puzzles = [a_puzzle(key)]
      sources = [a_source(key)]

      assert {:ok, _} = Puzzles.store(game_id, 1, puzzles, sources)
      first = review_row(game_id).puzzles_extracted_at

      assert {:ok, _} = Puzzles.store(game_id, 1, puzzles, sources)

      assert [_one] = puzzles_keyed(key)
      assert [_one_source] = sources_of(game_id)
      # The marker moves (the game was extracted again, harmlessly); the
      # rows do not.
      assert DateTime.compare(review_row(game_id).puzzles_extracted_at, first) != :lt
    end

    test "two games that reach the same position share one puzzle" do
      one = a_room()
      other = a_room()
      key = a_key()

      assert {:ok, _} = Puzzles.store(one, 1, [a_puzzle(key)], [a_source(key)])
      assert {:ok, _} = Puzzles.store(other, 1, [a_puzzle(key)], [a_source(key, turn: 9)])

      assert [puzzle] = puzzles_keyed(key)
      assert [first] = sources_of(one)
      assert [second] = sources_of(other)
      assert first.puzzle_id == puzzle.id
      assert second.puzzle_id == puzzle.id
    end

    test "an id another key already holds falls through to the next candidate" do
      game_id = a_room()
      key = a_key()
      [taken, second | _] = ids = some_ids()
      now = DateTime.utc_now()

      Repo.insert!(%Puzzles.Puzzle{
        id: taken,
        key: a_key(),
        kind: "double",
        question: %{},
        answer: %{},
        inserted_at: now,
        updated_at: now
      })

      assert {:ok, _} =
               Puzzles.store(game_id, 1, [a_puzzle(key, ids: ids)], [a_source(key)])

      assert %{id: ^second} = Repo.get_by(Puzzles.Puzzle, key: key)
      assert [%{puzzle_id: ^second}] = sources_of(game_id)
    end

    test "a skipped decision is a source with a reason and no puzzle" do
      game_id = a_room()

      assert {:ok, _} =
               Puzzles.store(game_id, 1, [], [
                 a_source(nil, skipped_reason: "post_take_cube")
               ])

      assert [source] = sources_of(game_id)
      assert is_nil(source.puzzle_id)
      assert source.skipped_reason == "post_take_cube"
      # Still extracted: there was nothing else to write.
      assert review_row(game_id).puzzles_extracted_at
    end

    test "a game with no mistakes is still marked, so the sweep lets it go" do
      game_id = a_room()

      assert {:ok, _} = Puzzles.store(game_id, 1, [], [])

      assert review_row(game_id).puzzles_extracted_at
      assert Puzzles.unextracted(game_id) == []
    end

    test "a puzzle whose ids are all taken is skipped, not fatal" do
      game_id = a_room()
      key = a_key()
      other = a_key()

      # One puzzle with no id left to try, one perfectly ordinary. Losing a
      # billion-to-one id race must not cost the game its other puzzles.
      assert {:ok, _} =
               Puzzles.store(
                 game_id,
                 1,
                 [a_puzzle(key, ids: []), a_puzzle(other)],
                 [a_source(key, turn: 4), a_source(other, turn: 5)]
               )

      assert puzzles_keyed(key) == []
      assert [written] = puzzles_keyed(other)

      assert [skipped, ordinary] = sources_of(game_id)
      assert is_nil(skipped.puzzle_id)
      assert skipped.skipped_reason == "id_exhausted"
      assert ordinary.puzzle_id == written.id
      assert is_nil(ordinary.skipped_reason)

      assert review_row(game_id).puzzles_extracted_at
    end

    test "a write that fails leaves no rows, no marker, and a spent attempt" do
      game_id = a_room()
      key = a_key()

      # A source with no turn: Postgres refuses it and the transaction goes.
      assert {:error, _reason} =
               Puzzles.store(game_id, 1, [a_puzzle(key)], [a_source(key, turn: nil)])

      assert puzzles_keyed(key) == []
      assert sources_of(game_id) == []

      row = review_row(game_id)
      assert is_nil(row.puzzles_extracted_at)
      # Charged outside the transaction, so a write that always fails does
      # not have the sweep replaying this room every minute for ever.
      assert row.puzzles_attempts == 1
    end

    test "a complete answer replaces an incomplete one for the same question, once" do
      game_id = a_room()
      key = a_key()
      incomplete = a_puzzle(key, complete: false)

      complete = %{
        a_puzzle(key)
        | answer: %{"kind" => "move", "complete" => true, "outcomes" => [1]}
      }

      assert {:ok, %{puzzles: 1, upgraded: 0}} =
               Puzzles.store(game_id, 1, [incomplete], [a_source(key)])

      assert [%{complete: false, answer_upgraded_at: nil}] = puzzles_keyed(key)

      # The same question with every result: the one sanctioned rewrite,
      # and it says so.
      assert {:ok, %{puzzles: 0, upgraded: 1, sources: 0}} =
               Puzzles.store(game_id, 1, [complete], [a_source(key)])

      assert [puzzle] = puzzles_keyed(key)
      assert puzzle.complete
      assert puzzle.answer["outcomes"] == [1]
      assert puzzle.answer_upgraded_at

      # Complete already: left exactly alone, however often it comes round.
      again = %{complete | answer: %{"kind" => "move", "complete" => true, "outcomes" => [2]}}
      assert {:ok, %{upgraded: 0}} = Puzzles.store(game_id, 1, [again], [a_source(key)])
      assert [%{answer: %{"outcomes" => [1]}}] = puzzles_keyed(key)
    end

    test "an incomplete answer never replaces anything" do
      game_id = a_room()
      key = a_key()

      assert {:ok, _} = Puzzles.store(game_id, 1, [a_puzzle(key)], [a_source(key)])
      assert [%{complete: true} = before] = puzzles_keyed(key)

      assert {:ok, %{upgraded: 0}} =
               Puzzles.store(game_id, 1, [a_puzzle(key, complete: false)], [a_source(key)])

      assert [^before] = puzzles_keyed(key)
    end

    test "a game that can never be extracted is swept three times and then never again" do
      game_id = a_room()
      key = a_key()

      always_fails = fn ->
        Puzzles.store(game_id, 1, [a_puzzle(key)], [a_source(key, turn: nil)])
      end

      assert {:error, _} = always_fails.()
      assert Puzzles.unextracted(game_id) == [1]

      assert {:error, _} = always_fails.()
      assert Puzzles.unextracted(game_id) == [1]

      assert {:error, _} = always_fails.()
      # The third try spends the budget and settles the row, so the minute
      # sweep stops replaying this room's log for a game it can never do.
      assert Puzzles.unextracted(game_id) == []
      refute game_id in Puzzles.rooms_owed_puzzles()

      row = review_row(game_id)
      assert row.puzzles_attempts == 3
      assert row.puzzles_extracted_at
      assert row.puzzles_error =~ "turn"
    end

    test "a decision Gleam could not reach at all is charged and given up on" do
      game_id = a_room()

      # What `failed/3` is for: a stored answer that no longer lines up with
      # the game's turns, where no row would otherwise leave the sweep.
      assert :ok = Puzzles.failed(game_id, 1, "The review does not match the game")
      assert Puzzles.unextracted(game_id) == [1]
      assert :ok = Puzzles.failed(game_id, 1, "The review does not match the game")
      assert :ok = Puzzles.failed(game_id, 1, "The review does not match the game")

      assert Puzzles.unextracted(game_id) == []
      row = review_row(game_id)
      assert row.puzzles_attempts == 3
      assert row.puzzles_error == "The review does not match the game"
    end

    test "a write that succeeds clears a game that had been given up on" do
      game_id = a_room()
      # Only the try that spends the budget records the reason; the earlier
      # ones just log and leave the game owed.
      assert :ok = Puzzles.failed(game_id, 1, "a passing squall")
      assert is_nil(review_row(game_id).puzzles_error)
      assert :ok = Puzzles.failed(game_id, 1, "a passing squall")
      assert :ok = Puzzles.failed(game_id, 1, "a passing squall")
      assert review_row(game_id).puzzles_error == "a passing squall"

      # An operator's retry, or a fresh enqueue, still writes cleanly.
      assert {:ok, _} = Puzzles.store(game_id, 1, [a_puzzle(a_key())], [])
      assert is_nil(review_row(game_id).puzzles_error)
      assert review_row(game_id).puzzles_extracted_at
    end
  end

  describe "reopen/2" do
    test "owes the game its puzzles again and drops only the post-take sources" do
      game_id = a_room()
      key = a_key()

      assert {:ok, _} =
               Puzzles.store(game_id, 1, [a_puzzle(key)], [
                 a_source(key, turn: 4),
                 a_source(nil, turn: 7, skipped_reason: "post_take_cube")
               ])

      assert review_row(game_id).puzzles_extracted_at
      assert :ok = Puzzles.reopen(game_id, 1)

      # The skipped turn can be written as a puzzle now; the real source
      # and the puzzle it points at stay.
      assert [%{turn: 4, puzzle_id: id}] = sources_of(game_id)
      assert [%{id: ^id}] = puzzles_keyed(key)
      row = review_row(game_id)
      assert is_nil(row.puzzles_extracted_at)
      assert is_nil(row.puzzles_error)
      assert row.puzzles_attempts == 0
      assert Puzzles.unextracted(game_id) == [1]
    end
  end

  describe "what is still owed" do
    test "a graded game with no puzzles is owed, and stops being owed once written" do
      game_id = a_room()

      assert Puzzles.unextracted(game_id) == [1]
      assert game_id in Puzzles.rooms_owed_puzzles()

      key = a_key()
      assert {:ok, _} = Puzzles.store(game_id, 1, [a_puzzle(key)], [a_source(key)])

      assert Puzzles.unextracted(game_id) == []
      refute game_id in Puzzles.rooms_owed_puzzles()
    end

    test "a review with no answer is owed nothing" do
      game_id = a_room(graded: false)
      :ok = Reviews.save(game_id, 1, "pending", 1, nil, nil, nil, 3)

      assert Puzzles.unextracted(game_id) == []
      refute game_id in Puzzles.rooms_owed_puzzles()
    end

    test "a game whose attempts are spent is left alone" do
      game_id = a_room()

      from(r in Reviews.Review, where: r.game_id == ^game_id)
      |> Repo.update_all(set: [puzzles_attempts: 3])

      assert Puzzles.unextracted(game_id) == []
      refute game_id in Puzzles.rooms_owed_puzzles()
    end
  end

  describe "the tables the later tickets write" do
    test "an attempt, a share and an image round-trip" do
      game_id = a_room()
      key = a_key()
      [id | _] = ids = some_ids()
      {:ok, _} = Puzzles.store(game_id, 1, [a_puzzle(key, ids: ids)], [a_source(key)])
      [source] = sources_of(game_id)
      user = Oskol.Auth.find_or_create_user(a_key() <> "@oskol.test")
      token = a_key()
      now = DateTime.utc_now()

      attempt =
        Repo.insert!(%Puzzles.Attempt{
          puzzle_id: id,
          user_id: user.id,
          idempotency_key: "once",
          answer: %{"moves" => [%{"from" => "13", "to" => "8", "die" => 5}]},
          verdict: "fail",
          scheduled: true,
          at: now,
          inserted_at: now,
          updated_at: now
        })

      assert Repo.get(Puzzles.Attempt, attempt.id).verdict == "fail"

      # One answer per opportunity: the same key twice is the same attempt.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%Puzzles.Attempt{
          puzzle_id: id,
          user_id: user.id,
          idempotency_key: "once",
          inserted_at: now,
          updated_at: now
        })
      end

      Repo.insert!(%Puzzles.Share{
        token: token,
        puzzle_id: id,
        source_id: source.id,
        shared_by: user.id,
        shared_name: "arie1",
        inserted_at: now
      })

      assert Repo.get(Puzzles.Share, token).shared_name == "arie1"

      Repo.insert!(%Puzzles.Image{
        puzzle_id: id,
        png: <<137, 80, 78, 71>>,
        rendered_at: now,
        attempts: 1,
        inserted_at: now,
        updated_at: now
      })

      assert Repo.get(Puzzles.Image, id).png == <<137, 80, 78, 71>>
    end

    test "a puzzle's rows go when its room does" do
      game_id = a_room()
      key = a_key()
      {:ok, _} = Puzzles.store(game_id, 1, [a_puzzle(key)], [a_source(key)])

      Repo.delete_all(from(g in Persistence.Game, where: g.id == ^game_id))

      # The source belongs to the game; the puzzle is everybody's and stays.
      assert sources_of(game_id) == []
      assert [_puzzle] = puzzles_keyed(key)
    end
  end
end
