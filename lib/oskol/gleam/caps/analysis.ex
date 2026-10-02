defmodule Oskol.Gleam.Caps.Analysis do
  @moduledoc """
  Real IO for src/oskol/caps/analysis.gleam. Keep constructor tags and field
  order in lockstep:

      AnalysisCaps(log, stored, ratings, summaries, report, save, backfill_turns,
      enqueue, review, report_turn, charge, replace, grades, forget_grades,
      graded_for, graded_rooms_for, mistake_costs, ask_budget, asking, submit,
      allow_ask, release_ask, stored_one)
      RatedGame(game_id, game_number, seat, response_json, ended_at_ms)
      GameLog(slug, format, clock, seed, seats, entries, record_generation)
      LogEntry(kind, player_id, payload_json, at_ms)
      Stored(game_number, status, attempts, response_json, answered, rendered, turns)
      Save(status, attempts, response_json, error, report_json, turns)
      GradedGame(game_id, game_number, slug, seat, player_id, opponent, winner,
      points, kind, response_json, ended_at_ms)
      GradedRoomGame(format, over, winners, game)
      Cursor(ended_at_ms, room_id)
      MistakeCost(puzzle_id, band, game_id, game_number, seat, equity_lost)
      AskBudget(guest_hour, guest_day, user_hour, user_day, global_day)
      Ask(key, ids, kind, question_json, request_body, buckets)
      Asker: :free | :asked | :full | {:down, retry_after_s}
      Refused(key, retry_after_s)
      LimitBucket(key, limit, window_s)   (src/oskol/caps/auth.gleam)
      Seat(player_id, guest_id, user_id, bot)   (src/oskol/rooms/seat.gleam)
      Status: :pending | :done | :failed

  `response` and `report` are hundreds of kilobytes each. `summaries`
  selects neither and `report/2` selects one of them for one game, so the
  only query that carries a body is the one whose answer is the body.
  `report_turn/3` goes further and has PostgreSQL take the path, so a
  caller that wants three integers out of a report reads three integers.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Reviews

  @doc """
  The caps. `:review` injects the engine call (an operator task wrapping it
  to time it, a test standing in for it); the default POSTs to the engine.

  `:grades` is the warm cache of turns graded while the game was still being
  played, and it is **off by default**: the context a request handler is
  given holds the panicking stub, so nothing a player can reach can count,
  list or hint at the grades of a game on the board. The review queue passes
  `grades: true` for its own job, which is the only reader there is.
  """
  def build(opts \\ []) do
    grades =
      if Keyword.get(opts, :grades, false),
        do: &grades/3,
        else: :oskol@caps@analysis.no_grades()

    {:analysis_caps, &log/1, &stored/1, &ratings/1, &summaries/1, &report/2, &save/3,
     &backfill_turns/3, &enqueue/1, Keyword.get(opts, :review, &review/1), &report_turn/3,
     &charge/4, &replace/3, grades, &forget_grades/2, &graded_for/2, &graded_rooms_for/3,
     &mistake_costs/1, &ask_budget/0, &Oskol.Analysis.Asker.asking/1,
     &Oskol.Analysis.Asker.submit/1, &Oskol.Limiter.allow/1, &release_ask/1, &stored_one/2}
  end

  defp release_ask(buckets) do
    :ok = Oskol.Limiter.release(buckets)
    nil
  end

  # The analysis board's budgets: numbers only. Which buckets an ask is
  # charged to, and what a refusal says, is `handlers/analysis`.
  defp ask_budget do
    config = Application.get_env(:oskol, :analysis_budget, [])

    {:ask_budget, positive(config, :guest_hour, 10), positive(config, :guest_day, 30),
     positive(config, :user_hour, 30), positive(config, :user_day, 150),
     positive(config, :global_day, 600)}
  end

  defp positive(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  # The grades stored for a game's turns, in the order the bodies were asked
  # about: the engine's reply where that exact question is answered already.
  # The body is the key, hashed here (`Reviews.turn_key/1`) over the bytes
  # Gleam built, so nothing between the two can reorder a key.
  defp grades(game_id, number, bodies) do
    game_id
    |> Reviews.turn_grades(number, bodies)
    |> Enum.map(&opt(&1, fn response -> Jason.encode!(response) end))
  end

  # Spent the moment the game's own answer is written.
  defp forget_grades(game_id, number) do
    :ok = Reviews.forget_turn_grades(game_id, number)
    nil
  end

  # One account's graded games, newest answer first, as a rating counts
  # them. The row already carries only the seats' totals out of the
  # engine's answer; everything this hands over is small, whatever the
  # answers behind it weigh.
  defp graded_for(user_id, limit) do
    user_id
    |> Reviews.graded_for(limit)
    |> Enum.map(fn row ->
      {:rated_game, row.game_id, row.game_number, row.seat, Jason.encode!(row.totals),
       DateTime.to_unix(row.ended_at, :millisecond)}
    end)
  end

  # The same rows counted in rooms, each carrying what the page needs to
  # know about the room it belongs to.
  defp graded_rooms_for(user_id, rooms, before) do
    user_id
    |> Reviews.graded_rooms_for(rooms, cursor(before))
    |> Enum.map(fn row ->
      {:graded_room_game, row.format, row.over, row.winners, graded_game(row)}
    end)
  end

  # Every mistake on a seat this account holds, each with the seat it was
  # made from: the holder rule is asked in Gleam, of the seat.
  defp mistake_costs(user_id) do
    user_id
    |> Reviews.mistake_costs()
    |> Enum.map(fn row ->
      {:mistake_cost, row.puzzle_id, row.band, row.game_id, row.game_number,
       {:seat, row.player_id, id(row.guest_id), id(row.user_id), row.bot},
       (row.equity_lost || 0.0) * 1.0}
    end)
  end

  # An empty id is no id at all, as `seat.of_rows` reads one.
  defp id(""), do: :none
  defp id(value), do: opt(value)

  defp graded_game(row) do
    {:graded_game, row.game_id, row.game_number, row.slug, row.seat, row.player_id,
     opt(row.opponent), opt(row.winner), row.points, row.kind, Jason.encode!(row.totals),
     DateTime.to_unix(row.ended_at, :millisecond)}
  end

  defp cursor(:none), do: nil

  defp cursor({:some, {:cursor, ended_at_ms, room_id}}) do
    {DateTime.from_unix!(ended_at_ms, :millisecond), room_id}
  end

  defp log(game_id) do
    case Reviews.log(game_id) do
      nil ->
        :none

      %{game: game, actions: actions} ->
        config = game.config || %{}

        {:some,
         {
           :game_log,
           game.slug,
           config["format"] || "",
           config["clock"] || "none",
           game.seed,
           # The names the seats play under, so a review names an account's
           # seat as the table and the replay do.
           Enum.map(hd(Oskol.Persistence.display_names([game.players])), fn p ->
             {p["id"], p["name"]}
           end),
           Enum.map(actions, fn a ->
             {:log_entry, a.kind, opt(a.player_id), Jason.encode!(a.payload), a.at_ms}
           end),
           Reviews.record_generation(game)
         }}
    end
  end

  defp stored(game_id) do
    Enum.map(Reviews.stored(game_id), &stored_row/1)
  end

  # One game's row with its answer: what sharing a replay step reads,
  # rather than every game of a match's.
  defp stored_one(game_id, game_number) do
    opt(Reviews.stored_one(game_id, game_number), &stored_row/1)
  end

  defp ratings(game_id) do
    Enum.map(Reviews.rating_summaries(game_id), &stored_row/1)
  end

  defp stored_row(r) do
    {:stored, r.game_number, status(r.status), r.attempts, opt(r.response, &Jason.encode!/1),
     r.response != nil, r.rendered, r.turns || 0}
  end

  defp summaries(game_id) do
    Enum.map(Reviews.summaries(game_id), fn r ->
      {:stored, r.game_number, status(r.status), r.attempts, :none, r.answered, r.rendered,
       r.turns || 0}
    end)
  end

  defp report_turn(game_id, number, turn) do
    opt(Reviews.report_turn(game_id, number, turn), &Jason.encode!/1)
  end

  defp report(game_id, number) do
    opt(Reviews.report(game_id, number), &Jason.encode!/1)
  end

  defp status("pending"), do: :pending
  defp status("done"), do: :done
  defp status("failed"), do: :failed

  defp save(game_id, number, {:save, status, attempts, response, error, report, turns}) do
    :ok =
      Reviews.save(
        game_id,
        number,
        Atom.to_string(status),
        attempts,
        decode(response),
        unopt(error),
        decode(report),
        turns
      )

    nil
  end

  # A legacy row needs just its count filled in. Do not turn this into a
  # `save`: a queue worker can have updated status/error after the caller
  # read its snapshot, and that newer state must survive this backfill.
  defp backfill_turns(game_id, number, turns) do
    :ok = Reviews.backfill_turns(game_id, number, turns)
    nil
  end

  defp decode(option) do
    if json = unopt(option), do: Jason.decode!(json)
  end

  # A note before the ask, always. The queue lives in memory, so anything
  # that asks it for work -- today a player's retry of a failed analysis --
  # must leave something behind that a restart cannot forget. Writing it
  # here rather than at each call site means a new caller cannot omit it.
  # This also advances record freshness: a read before the retry job has
  # re-saved its checkpoint can pay one replay. Ordinary polling cannot
  # advance the marker or trigger repeated backfills.
  defp enqueue(game_id) do
    Reviews.mark_analysis_owed(game_id)
    Oskol.Reviews.Queue.enqueue(game_id)
    nil
  end

  # The backfill's charge against a `done` row: attempts and error only, so
  # the answer and the page a reader is served stay exactly as they were.
  defp charge(game_id, number, attempts, error) do
    :ok = Reviews.charge(game_id, number, attempts, unopt(error))
    nil
  end

  # The backfill's one write of a fresh answer: the row as `save` writes
  # it, and the game's puzzles reopened, in one transaction.
  defp replace(game_id, number, {:save, status, attempts, response, error, report, turns}) do
    :ok =
      Reviews.replace(
        game_id,
        number,
        Atom.to_string(status),
        attempts,
        decode(response),
        unopt(error),
        decode(report),
        turns
      )

    nil
  end

  defp review(body) do
    case Reviews.request(body) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
