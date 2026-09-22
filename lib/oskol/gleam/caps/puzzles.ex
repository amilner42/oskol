defmodule Oskol.Gleam.Caps.Puzzles do
  @moduledoc """
  Real IO for src/oskol/caps/puzzles.gleam. Keep constructor tags and field
  order in lockstep:

      PuzzlesCaps(unextracted, store, failed, owned_sources, mark_synced,
      sync_failed, deck_pending, guest_sources, get, mine, game_sources,
      put_attempt, attempt, settle_attempt, serialize, cached_tree, keep_tree,
      cached_moves, keep_moves, pictures, sample)
      NewPuzzle(key, ids, kind, question_json, answer_json, evaluated_by_json,
      complete)
      Written(puzzles, upgraded, sources)
      NewSource(key, game_number, turn, kind, seat, player_id, played,
      equity_lost, grade, skipped_reason)
      DeckSource(source_id, puzzle_id, game_id, game_number, kind, turn,
      question_json, ended_ms, seat)
      Pending(user_id, game_ids, sources)
      Stored(id, kind, question_json, answer_json)
      Source(id, puzzle_id, kind, game_id, game_number, turn, seat,
      player_id, played, equity_lost, grade, date, question_json)
      SourceRoom(source, slug, seats)
      Attempt(id, puzzle_id, user_id, key, verdict, outcome, scheduled,
      review_id, schedule_json, fresh)
      Scheduled(verdict, schedule_json)

  A question, an answer and an evaluator cross as JSON text: Gleam wrote
  them and Gleam reads them back, so nothing here looks inside one.

  `store` never raises. Extraction is a bonus on top of a review that has
  already been stored, so a failure is logged and the game left unmarked
  for the sweep to try again within its budget.
  """

  import Oskol.Gleam.Interop

  require Logger

  alias Oskol.Puzzles
  alias Oskol.Puzzles.TreeCache

  def build do
    {:puzzles_caps, &Puzzles.unextracted/1, &store/4, &failed/3, &owned_sources/2, &mark_synced/1,
     &sync_failed/2, &deck_pending/2, &guest_sources/1, &get/1, &mine/3, &game_sources/2,
     &put_attempt/5, &attempt/3, &settle_attempt/5, &serialize/3, &cached_tree/1, &keep_tree/2,
     &cached_moves/1, &keep_moves/2, &pictures/2, &sample/1}
  end

  defp get(id) do
    opt(Puzzles.get(id), &stored/1)
  end

  # The pool TRY ONE draws from: complete answers only, in the database's
  # own random order. Gleam picks from what comes back.
  defp sample(n) do
    Enum.map(Puzzles.sample(n), &stored/1)
  end

  defp stored(row) do
    {:stored, row.id, row.kind, Jason.encode!(row.question), Jason.encode!(row.answer)}
  end

  defp mine(puzzle_id, guest_id, user_id) do
    Enum.map(Puzzles.mine(puzzle_id, guest_id, user_id), fn {source, slug, players, ended_at} ->
      {:source_room, source(%{source | inserted_at: ended_at}, nil), slug,
       Enum.map(players, fn p ->
         {p["id"] || "", p["name"] || "", p["guest_id"] || "", p["user_id"] || ""}
       end)}
    end)
  end

  defp game_sources(game_id, game_number) do
    Enum.map(Puzzles.game_sources(game_id, game_number), fn {source, question} ->
      source(source, question)
    end)
  end

  # A source, with its puzzle's question where the caller asked for it. A
  # date is a day, not a moment: the memory line says "12 Sep", never a
  # time, so that is all that crosses -- and for the memory line it is the
  # day the game ended (`mine` above swaps the review's moment in), not the
  # day the source was written.
  defp source(s, question) do
    {:source, s.id, s.puzzle_id || "", s.kind, s.game_id, s.game_number, s.turn, s.seat,
     s.player_id || "", s.played || "", s.equity_lost || 0.0, s.grade || "",
     s.inserted_at |> DateTime.to_date() |> Date.to_iso8601(),
     if(question, do: Jason.encode!(question), else: "")}
  end

  defp put_attempt(puzzle_id, user_id, key, answer, verdict) do
    {freshness, row} =
      Puzzles.put_attempt(puzzle_id, user_id, key, Jason.decode!(answer), verdict)

    attempt_row(row, freshness == :fresh)
  end

  defp attempt(puzzle_id, user_id, key) do
    opt(Puzzles.attempt(puzzle_id, user_id, key), &attempt_row(&1, false))
  end

  defp attempt_row(row, fresh) do
    {:attempt, row.id, row.puzzle_id, row.user_id, row.idempotency_key, row.verdict || "",
     opt(row.outcome), row.scheduled, opt(row.review_id),
     if(row.schedule, do: Jason.encode!(row.schedule), else: ""), fresh}
  end

  defp settle_attempt(id, scheduled, review_id, outcome, schedule) do
    :ok =
      Puzzles.settle_attempt(id, scheduled, unopt(review_id), unopt(outcome), decoded(schedule))

    nil
  end

  # Gleam decides what an answer does; this only makes sure two requests
  # are not deciding it about the same card at the same moment.
  defp serialize(user_id, puzzle_id, decide) do
    Puzzles.serialize(user_id, puzzle_id, decide)
  end

  defp decoded(""), do: nil
  defp decoded(json), do: Jason.decode!(json)

  defp cached_tree(id), do: opt(TreeCache.get(id))

  defp keep_tree(id, text) do
    :ok = TreeCache.put(id, text)
    nil
  end

  # A built tree crosses as itself. Gleam made it, Gleam reads it, and this
  # only holds onto it -- the same way a room process crosses as an opaque
  # handle.
  defp cached_moves(id), do: opt(TreeCache.moves(id))

  defp keep_moves(id, tree) do
    :ok = TreeCache.put_moves(id, tree)
    nil
  end

  # The deck's own capabilities degrade rather than raise, the way
  # `seated_rooms` does: they are asked from inside the review job's task
  # and from the sweep, and a database hiccup must not lose a review that
  # has already been stored or take a sweep down. Nothing is marked, so the
  # next sweep does exactly the work this one did not.
  defp owned_sources(user_id, game_ids) do
    quietly([], fn -> user_id |> Puzzles.owned_sources(game_ids) |> Enum.map(&deck_source/1) end)
  end

  defp mark_synced(ids) do
    quietly(nil, fn ->
      :ok = Puzzles.mark_synced(ids)
      nil
    end)
  end

  defp sync_failed(ids, reason) do
    quietly(nil, fn ->
      :ok = Puzzles.sync_failed(ids, reason)
      nil
    end)
  end

  defp deck_pending(game_ids, limit) do
    quietly([], fn ->
      for row <- Puzzles.deck_pending(game_ids, limit) do
        {:pending, row.user_id, row.game_ids, row.sources}
      end
    end)
  end

  defp guest_sources(guest_id) do
    quietly([], fn -> guest_id |> Puzzles.guest_sources() |> Enum.map(&deck_source/1) end)
  end

  # A picture is a bonus on top of a stored puzzle: the render bounds and
  # logs its own failures, and anything past that is logged here and left
  # for the sweep.
  defp pictures(game_id, game_number) do
    quietly(nil, fn ->
      Oskol.Puzzles.Pictures.render_game(game_id, game_number)
      nil
    end)
  end

  defp quietly(fallback, fun) do
    fun.()
  rescue
    e ->
      Logger.error("deck capability failed: #{Exception.message(e)}")
      fallback
  end

  # A seat crosses as the Gleam seat rules read it, exactly as a `games`
  # row's seats do: the holder rule is Gleam's, and nothing here judges an
  # id. A stored question crosses as the JSON text Gleam wrote.
  defp deck_source(row) do
    {:deck_source, row.id, row.puzzle_id, row.game_id, row.game_number, row.kind, row.turn,
     Jason.encode!(row.question), DateTime.to_unix(row.ended_at, :millisecond),
     {:seat, row.player_id, opt(blank_to_nil(row.guest_id)), opt(blank_to_nil(row.user_id))}}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp store(game_id, game_number, puzzles, sources) do
    case Puzzles.store(
           game_id,
           game_number,
           Enum.map(puzzles, &puzzle/1),
           Enum.map(sources, &source/1)
         ) do
      {:ok, counts} -> {:ok, {:written, counts.puzzles, counts.upgraded, counts.sources}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp failed(game_id, game_number, reason) do
    :ok = Puzzles.failed(game_id, game_number, reason)
    nil
  end

  defp puzzle({:new_puzzle, key, ids, kind, question, answer, evaluated_by, complete}) do
    %{
      key: key,
      ids: ids,
      kind: kind,
      question: Jason.decode!(question),
      answer: Jason.decode!(answer),
      evaluated_by: Jason.decode!(evaluated_by),
      complete: complete
    }
  end

  defp source(
         {:new_source, key, game_number, turn, kind, seat, player_id, played, equity_lost, grade,
          skipped_reason}
       ) do
    %{
      key: unopt(key),
      game_number: game_number,
      turn: turn,
      kind: kind,
      seat: seat,
      player_id: player_id,
      played: played,
      equity_lost: equity_lost,
      grade: grade,
      skipped_reason: unopt(skipped_reason)
    }
  end
end
