defmodule Oskol.BackfillCase do
  @moduledoc """
  The ground under the puzzles-backfill tests: a room graded under the old
  contract, an engine that is a `Req.Test` stub, and the sandbox shared
  because rooms and the persister reach the database from their own
  processes.

  It is a case template so those tests can live in more than one file.
  `bin/test-par` splits the suite by file, and the backfill is one of its two
  slowest: kept whole it is a floor under every partitioned run.
  """
  use ExUnit.CaseTemplate

  import Ecto.Query
  import ExUnit.Assertions
  import Oskol.GameFixtures

  alias Oskol.Game.Persister
  alias Oskol.Puzzles
  alias Oskol.Puzzles.Backfill
  alias Oskol.Repo
  alias Oskol.Reviews

  using do
    quote do
      use ExUnit.Case, async: false

      import Ecto.Query
      import Oskol.BackfillCase
      import Oskol.GameFixtures

      @n_legal Oskol.BackfillCase.n_legal()

      alias Oskol.Game.Persister
      alias Oskol.Puzzles
      alias Oskol.Puzzles.Backfill
      alias Oskol.Repo
      alias Oskol.Reviews
    end
  end

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
  def old_room(seed) do
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
  def turns_of(game_id) do
    {:some, game_log} = game_log(game_id)
    {:ok, [{:game_turns, 1, true, _jacoby, turns}]} = :oskol@handlers@reviews.games(game_log)
    turns
  end

  # The room's log as the analysis cap hands it to Gleam (`log` is the
  # cap's first field, whatever else it grows).
  def game_log(game_id) do
    caps = Oskol.Gleam.Caps.Analysis.build()
    :analysis_caps = elem(caps, 0)
    elem(caps, 1).(game_id)
  end

  # The page the old answer renders to, built the one way pages are built.
  def rendered(game_id, response, _turns) do
    {:some, game_log} = game_log(game_id)
    {:ok, [g]} = :oskol@handlers@reviews.games(game_log)
    seats = [{:seat, "p1", "Alice", "white"}, {:seat, "p2", "Bob", "black"}]
    {:ok, {_review, page}} = :oskol@handlers@reviews.rendered(Jason.encode!(response), g, seats)
    Jason.decode!(page)
  end

  # An engine answer for these turns: every candidate is the move that was
  # played, board and all; every checker play a mistake worth 0.05 (so a
  # puzzle); a result per legal play when `complete`.
  # How many legal plays the stub's answers offer. The tests assert against
  # it too, so it is injected into them below rather than written twice.
  @n_legal 3

  @doc "How many legal plays the stub reports for a graded turn."
  def n_legal, do: @n_legal

  def answer(turns, opts) do
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

  def move(board, complete?) do
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

  def totals do
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
  def engine(test_pid, respond) do
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
  def fresh(request) do
    {:ok, request_answer(request, complete: true)}
  end

  def request_answer(request, opts) do
    turns =
      for t <- request["turns"] do
        dice = if t["dice"], do: {:some, t["dice"]}, else: :none
        played = if t["played"], do: {:some, t["played"]}, else: :none

        {:turn, 0, "p1", {:position, t["board"], 1, "centered", 0, 0, false}, :none, dice, played,
         0, :none, :none, :none}
      end

    answer(turns, opts)
  end

  def engine_calls do
    receive do
      {:engine, request} -> [request | engine_calls()]
    after
      0 -> []
    end
  end

  def review_row(game_id), do: Repo.get_by!(Reviews.Review, game_id: game_id, game_number: 1)

  def sources_of(game_id) do
    from(s in Puzzles.Source, where: s.game_id == ^game_id, order_by: s.turn) |> Repo.all()
  end

  def puzzles_of(game_id) do
    from(p in Puzzles.Puzzle,
      join: s in Puzzles.Source,
      on: s.puzzle_id == p.id,
      where: s.game_id == ^game_id,
      distinct: true
    )
    |> Repo.all()
  end

  def run(opts), do: Backfill.run(Keyword.put(opts, :say, fn _line -> :ok end))

  def old?(row) do
    Enum.any?(row.response["turns"], fn t ->
      is_map(t["move"]) and not Map.has_key?(t["move"], "results")
    end)
  end
end
