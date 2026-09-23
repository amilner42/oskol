defmodule Oskol.Puzzles.BackfillTest do
  @moduledoc """
  The puzzles backfill end to end, against a Req.Test engine: a game graded
  before `all_results` is asked again at its stored levels, its answer and
  page replaced, its puzzles written complete and the ones written from
  the old answer upgraded; a fresh answer that cannot be trusted is
  quarantined; an engine failure is charged and skipped; a dry run and a
  second run write nothing. What is old, what is trusted and what is
  written in what order are decided and tested in Gleam
  (test/oskol/backfill_test.gleam).
  """
  # Rooms and the persister touch the database from their own processes.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Oskol.GameFixtures

  alias Oskol.Game.Persister
  alias Oskol.Puzzles
  alias Oskol.Puzzles.Backfill
  alias Oskol.Repo
  alias Oskol.Reviews

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    Req.Test.set_req_test_to_shared()

    on_exit(fn ->
      Persister.flush()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  # ---------- A room graded under the old contract ----------

  # A finished single game whose review row holds an answer without
  # `results`, rendered, and -- as the migration left every old row --
  # marked extracted with nothing extracted.
  defp old_room(seed) do
    %{game_id: game_id} = started(seed, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, seed, 3000)
    Persister.flush()
    turns = turns_of(game_id)
    old = answer(turns, complete: false)
    page = rendered(game_id, old, turns)
    :ok = Reviews.save(game_id, 1, "done", 1, old, nil, page, length(turns))

    from(r in Reviews.Review, where: r.game_id == ^game_id)
    |> Repo.update_all(
      set: [
        puzzles_extracted_at: DateTime.utc_now(),
        puzzles_error: "graded before puzzles existed"
      ]
    )

    {game_id, turns}
  end

  # The game's turns as the replay reads them, through the same log the
  # review reads.
  defp turns_of(game_id) do
    {:some, game_log} = game_log(game_id)
    {:ok, [{:game_turns, 1, true, _jacoby, turns}]} = :oskol@handlers@reviews.games(game_log)
    turns
  end

  # The room's log as the analysis cap hands it to Gleam (`log` is the
  # cap's first field, whatever else it grows).
  defp game_log(game_id) do
    caps = Oskol.Gleam.Caps.Analysis.build()
    :analysis_caps = elem(caps, 0)
    elem(caps, 1).(game_id)
  end

  # The page the old answer renders to, built the one way pages are built.
  defp rendered(game_id, response, _turns) do
    {:some, game_log} = game_log(game_id)
    {:ok, [g]} = :oskol@handlers@reviews.games(game_log)
    seats = [{:seat, "p1", "Alice", "white"}, {:seat, "p2", "Bob", "black"}]
    {:ok, {_review, page}} = :oskol@handlers@reviews.rendered(Jason.encode!(response), g, seats)
    Jason.decode!(page)
  end

  # An engine answer for these turns: every candidate is the move that was
  # played, board and all; every checker play a mistake worth 0.05 (so a
  # puzzle); a result per legal play when `complete`.
  @n_legal 3

  defp answer(turns, opts) do
    complete? = Keyword.fetch!(opts, :complete)

    %{
      "levels" => %{"move" => "4ply", "cube" => "4ply"},
      "timing_ms" => 2500,
      "turns" =>
        turns
        |> Enum.with_index()
        |> Enum.map(fn {{:turn, _player, _pid, {:position, board, _, _, _, _, _}, _double, dice,
                         played, _, _, _, _}, i} ->
          move =
            case {dice, played} do
              {:none, _} ->
                nil

              # A dance carries an empty `results` under the new contract,
              # as the engine writes it: every move has it or none does.
              {{:some, _}, {:some, ^board}} when complete? ->
                %{"danced" => true, "n_legal" => 0, "results" => []}

              {{:some, _}, {:some, ^board}} ->
                %{"danced" => true, "n_legal" => 0}

              {{:some, _}, {:some, after_move}} ->
                move(after_move, complete?)
            end

          %{"index" => i, "cube" => nil, "move" => move, "luck" => nil}
        end),
      "players" => [totals(), totals()]
    }
  end

  defp move(board, complete?) do
    candidate = fn rank, diff ->
      %{
        "rank" => rank,
        "notation" => "8/5 6/5",
        "board" => board,
        "equity" => 0.1,
        "equity_diff" => diff,
        "probs" => %{
          "win" => 0.5,
          "gammon_win" => 0.1,
          "backgammon_win" => 0,
          "gammon_loss" => 0.1,
          "backgammon_loss" => 0
        }
      }
    end

    base = %{
      "played" => candidate.(2, -0.05),
      "best" => candidate.(1, 0.0),
      "top" => [candidate.(1, 0.0), candidate.(2, -0.05)],
      "n_legal" => @n_legal,
      "forced" => false,
      "error" => 0.05,
      "grade" => "doubtful"
    }

    if complete?,
      do:
        Map.put(
          base,
          "results",
          List.duplicate(%{"board" => board, "equity_diff" => 0}, @n_legal)
        ),
      else: base
  end

  defp totals do
    %{
      "moves" => %{"decisions" => 3, "forced" => 1, "error" => 0, "grades" => %{}},
      "cube" => %{"decisions" => 0, "error" => 0, "mistakes" => %{}},
      "luck" => 0,
      "error" => 0,
      "pr" => 0
    }
  end

  # ---------- The engine ----------

  # Answers each request with what `respond` says (a function of the
  # decoded request), and tells the test what it was asked.
  defp engine(test_pid, respond) do
    Req.Test.stub(Reviews, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      request = Jason.decode!(body)
      send(test_pid, {:engine, request})

      case respond.(request) do
        {:ok, answer} ->
          Req.Test.json(conn, answer)

        {:error, status} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"detail" => "no"})
      end
    end)
  end

  # The fresh answer for a request: the turns it asked about, graded with
  # every result. Built from the request itself so one stub serves every
  # room.
  defp fresh(request) do
    {:ok, request_answer(request, complete: true)}
  end

  defp request_answer(request, opts) do
    turns =
      for t <- request["turns"] do
        dice = if t["dice"], do: {:some, t["dice"]}, else: :none
        played = if t["played"], do: {:some, t["played"]}, else: :none

        {:turn, 0, "p1", {:position, t["board"], 1, "centered", 0, 0, false}, :none, dice, played,
         0, :none, :none, :none}
      end

    answer(turns, opts)
  end

  defp engine_calls do
    receive do
      {:engine, request} -> [request | engine_calls()]
    after
      0 -> []
    end
  end

  defp review_row(game_id), do: Repo.get_by!(Reviews.Review, game_id: game_id, game_number: 1)

  defp sources_of(game_id) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id, order_by: s.turn) |> Repo.all()
  end

  defp puzzles_of(game_id) do
    from(p in Puzzles.Puzzle,
      join: s in Puzzles.Source,
      on: s.puzzle_id == p.id,
      where: s.game_id == ^game_id,
      distinct: true
    )
    |> Repo.all()
  end

  defp run(opts), do: Backfill.run(Keyword.put(opts, :say, fn _line -> :ok end))

  defp old?(row) do
    Enum.any?(row.response["turns"], fn t ->
      is_map(t["move"]) and not Map.has_key?(t["move"], "results")
    end)
  end

  # ---------- Tests ----------

  test "an old game is re-asked at its levels, re-rendered and extracted complete" do
    {game_id, turns} = old_room(31)
    engine(self(), &fresh/1)
    before = review_row(game_id)
    assert old?(before)

    totals = run(write: true, room: game_id)

    assert [request] = engine_calls()
    assert request["all_results"] == true
    assert request["move_level"] == "4ply"
    assert request["cube_level"] == "4ply"
    assert length(request["turns"]) == length(turns)

    row = review_row(game_id)
    refute old?(row)
    assert row.status == "done"
    assert row.attempts == 2
    assert is_nil(row.error)
    assert row.report != before.report
    assert row.puzzles_extracted_at
    assert is_nil(row.puzzles_error)

    mistakes =
      Enum.count(turns, fn {:turn, _, _, {:position, board, _, _, _, _, _}, _, dice, played, _, _,
                            _, _} ->
        dice != :none and played != {:some, board}
      end)

    assert length(sources_of(game_id)) == mistakes
    assert mistakes > 0
    puzzles = puzzles_of(game_id)
    assert puzzles != []
    assert Enum.all?(puzzles, & &1.complete)
    assert Enum.all?(puzzles, &(&1.answer["complete"] == true))
    assert Enum.all?(puzzles, &(length(&1.answer["outcomes"]) == @n_legal))
    assert Enum.all?(puzzles, &is_nil(&1.answer_upgraded_at))

    assert totals.games == 1
    assert totals.reasked == 1
    assert totals.puzzles == length(puzzles)
    assert totals.sources == mistakes
    assert totals.engine_ms == 2500
    assert totals.quarantined == %{}
    assert totals.failed == 0
  end

  test "puzzles written from the old answer are upgraded; a complete one is left alone" do
    {game_id, _turns} = old_room(32)
    # The sweep's own extraction of the old answer, as production did
    # before the migration marked every old row.
    from(r in Reviews.Review, where: r.game_id == ^game_id)
    |> Repo.update_all(set: [puzzles_extracted_at: nil, puzzles_error: nil])

    :ok = Oskol.Reviews.Queue.run(game_id)
    old = puzzles_of(game_id)
    assert old != []
    assert Enum.all?(old, &(&1.complete == false))

    # One of them, complete already by some other game's answer: it must
    # not be touched.
    [settled | _] = old
    sentinel = %{settled.answer | "outcomes" => [%{"board" => [], "equity_lost" => 0.0}]}

    from(p in Puzzles.Puzzle, where: p.id == ^settled.id)
    |> Repo.update_all(set: [complete: true, answer: sentinel])

    engine(self(), &fresh/1)
    totals = run(write: true, room: game_id)

    assert [_one] = engine_calls()
    after_run = puzzles_of(game_id)
    assert length(after_run) == length(old)
    upgraded = Enum.reject(after_run, &(&1.id == settled.id))
    assert Enum.all?(upgraded, & &1.complete)
    assert Enum.all?(upgraded, & &1.answer_upgraded_at)
    assert Enum.all?(upgraded, &(&1.answer["complete"] == true))
    kept = Enum.find(after_run, &(&1.id == settled.id))
    assert kept.answer == sentinel
    assert is_nil(kept.answer_upgraded_at)

    assert totals.upgraded == length(upgraded)
    assert totals.puzzles == 0
    assert totals.sources == 0
    # The same rows, still one source per mistake.
    assert length(sources_of(game_id)) == length(old)
  end

  test "an answer that cannot be trusted is quarantined, counted, and not asked again" do
    {game_id, _turns} = old_room(33)
    before = review_row(game_id)
    # The engine still answers the old way.
    engine(self(), fn request -> {:ok, request_answer(request, complete: false)} end)

    totals = run(write: true, room: game_id)

    assert [_one] = engine_calls()
    assert totals.quarantined == %{"results_missing" => 1}
    assert totals.reasked == 0
    row = review_row(game_id)
    assert row.response == before.response
    assert row.report == before.report
    assert row.attempts == 3
    assert row.error =~ "quarantined: results_missing"
    assert row.puzzles_extracted_at == before.puzzles_extracted_at
    assert sources_of(game_id) == []

    # Spent: the next run says so and spends no engine time.
    again = run(write: true, room: game_id)
    assert engine_calls() == []
    assert again.spent == 1
    assert again.games == 0

    # Until an operator lets it try again, with the engine fixed.
    engine(self(), &fresh/1)
    reset = run(write: true, room: game_id, reset: true)
    assert [_one] = engine_calls()
    assert reset.reset == 1
    assert reset.reasked == 1
    refute old?(review_row(game_id))
  end

  test "an engine failure is charged, skipped, and the run goes on" do
    {failing, _} = old_room(34)
    {fine, _} = old_room(35)
    # Rooms come oldest first: the first request fails, the second lands.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    engine(self(), fn request ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:error, 503}
        _ -> fresh(request)
      end
    end)

    totals = run(write: true)

    assert length(engine_calls()) == 2
    assert totals.failed == 1
    assert totals.reasked == 1
    failed_row = review_row(failing)
    assert old?(failed_row)
    assert failed_row.attempts == 2
    assert failed_row.error =~ "HTTP 503"
    assert failed_row.status == "done"
    refute old?(review_row(fine))
  end

  test "a dry run asks nothing and writes nothing" do
    {game_id, _turns} = old_room(36)
    before = review_row(game_id)
    engine(self(), fn _ -> flunk("a dry run never asks the engine") end)

    totals = run(room: game_id)

    assert engine_calls() == []
    assert totals.games == 1
    assert totals.reasked == 0
    assert review_row(game_id) == before
    assert sources_of(game_id) == []
  end

  test "a second run finds nothing to do and writes nothing" do
    {game_id, _turns} = old_room(37)
    engine(self(), &fresh/1)
    assert %{reasked: 1} = run(write: true, room: game_id)
    assert [_one] = engine_calls()
    settled = review_row(game_id)
    puzzles = puzzles_of(game_id)

    again = run(write: true, room: game_id)

    assert engine_calls() == []
    assert again.games == 0
    assert again.reasked == 0
    assert again.puzzles == 0
    assert again.upgraded == 0
    assert review_row(game_id) == settled
    assert puzzles_of(game_id) == puzzles
  end

  test "a game already graded with every result is not a candidate" do
    %{game_id: game_id} = started(38, "single")
    assert {:finished, _} = Oskol.Bots.play(game_id, 38, 3000)
    Persister.flush()
    turns = turns_of(game_id)
    new = answer(turns, complete: true)

    :ok =
      Reviews.save(game_id, 1, "done", 1, new, nil, rendered(game_id, new, turns), length(turns))

    engine(self(), fn _ -> flunk("nothing to ask") end)

    totals = run(write: true, room: game_id)

    assert engine_calls() == []
    assert totals.games == 0
    assert totals.rooms == 1
  end
end
