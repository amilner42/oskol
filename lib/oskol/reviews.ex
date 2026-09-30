defmodule Oskol.Reviews do
  @moduledoc """
  Post-game reviews: storage, the persisted log they are built from, and
  the HTTP call to the analysis engine (the `oskol-analysis` Fly app, see
  the `bg-analysis-service` doc).

  Nothing here decides anything. What a review is, when one is owed, and
  what a page reads live in `src/oskol/handlers/reviews.gleam`; this is the
  IO behind `src/oskol/caps/analysis.gleam` (built in
  `Oskol.Gleam.Caps.Analysis`), and `Oskol.Reviews.Queue` runs the jobs.

  Config (`config :oskol, :analysis`):

    * `:url` — the engine's base URL. Prod: `ANALYSIS_URL`, default
      `http://oskol-analysis.flycast` (Flycast goes through Fly's proxy, so
      the first request wakes the stopped machine).
    * `:inet6` — connect over IPv6, as Fly's private network needs.
    * `:receive_timeout` — 20 minutes: a long game at the engine's 4-ply
      default takes minutes, and a machine scaled to zero starts first.
    * `:req_options` — merged into the request (tests stub with Req.Test).
  """

  import Ecto.Query
  alias Oskol.Repo

  defmodule Review do
    @moduledoc "One game of a room, reviewed (or on its way)."
    use Ecto.Schema

    @primary_key false
    schema "game_reviews" do
      field(:game_id, :string, primary_key: true)
      field(:game_number, :integer, primary_key: true)
      field(:status, :string)
      field(:attempts, :integer, default: 0)
      field(:response, :map)
      field(:error, :string)
      # The rendered analysis of this game, as the page reads it, built when
      # the engine's answer landed.
      field(:report, :map)
      # How many turns this game had; 0 is a game with nothing to grade.
      field(:turns, :integer)
      # When this game's puzzles were written (Oskol.Puzzles), and how many
      # tries that has taken. Set in the same transaction as the rows.
      field(:puzzles_extracted_at, :utc_datetime_usec)
      field(:puzzles_attempts, :integer, default: 0)
      # Why extraction was given up on, when it was. Nil on a row whose
      # puzzles were written.
      field(:puzzles_error, :string)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule TurnGrade do
    @moduledoc """
    One turn already graded, waiting for the game it belongs to to end.

    Keyed by the sha256 of the request the engine was asked, so the row is
    found by the question it answers and by nothing else. A cache: the only
    reader is the end-of-game review job, and losing every row of it costs
    one batch review.
    """
    use Ecto.Schema

    @primary_key false
    schema "turn_grades" do
      field(:game_id, :string, primary_key: true)
      field(:game_number, :integer, primary_key: true)
      field(:turn_key, :string, primary_key: true)
      field(:response, :map)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Record do
    @moduledoc "One finished game of a room, as its record lists it."
    use Ecto.Schema

    @primary_key false
    schema "game_records" do
      field(:game_id, :string, primary_key: true)
      field(:game_number, :integer, primary_key: true)
      field(:entries, {:array, :map})
      field(:finished, :boolean, default: true)

      timestamps(type: :utc_datetime_usec)
    end
  end

  # ---------- Storage ----------

  @doc """
  Every stored review of a room, by game number, the engine's answers
  included. `report` is never selected here: it is the one thing a per-game
  read sends, and `report/2` fetches it on its own.
  """
  def stored(game_id) do
    from(r in Review,
      where: r.game_id == ^game_id,
      order_by: r.game_number,
      select: %{
        game_number: r.game_number,
        status: r.status,
        attempts: r.attempts,
        response: r.response,
        error: r.error,
        rendered: not is_nil(r.report),
        turns: r.turns
      }
    )
    |> Repo.all()
  end

  @doc """
  The same rows without either body: where each game's analysis stands, and
  nothing a read has to carry. This is what the index is built from, so
  asking for it is a few hundred bytes off disk however big the answers are.
  """
  def summaries(game_id) do
    from(r in Review,
      where: r.game_id == ^game_id,
      order_by: r.game_number,
      select: %{
        game_number: r.game_number,
        status: r.status,
        attempts: r.attempts,
        answered: not is_nil(r.response),
        rendered: not is_nil(r.report),
        turns: r.turns
      }
    )
    |> Repo.all()
  end

  @doc "Review metadata and player totals only; never transfer turn analysis to a ratings reader."
  def rating_summaries(game_id) do
    from(r in Review,
      where: r.game_id == ^game_id,
      order_by: r.game_number,
      select: %{
        game_number: r.game_number,
        status: r.status,
        attempts: r.attempts,
        # The seats' totals, and the first turn's seat and cube verdict:
        # all `report.player_prs` needs to leave out the opening roll's
        # "no double", which nobody could have offered.
        response:
          fragment(
            """
            CASE WHEN ? IS NULL THEN NULL ELSE jsonb_build_object(
              'players', ?->'players',
              'turns', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'player', ?->'turns'->0->'player',
                'cube', ?->'turns'->0->'cube'))))
            END
            """,
            r.response,
            r.response,
            r.response,
            r.response
          ),
        rendered: not is_nil(r.report),
        turns: r.turns
      }
    )
    |> Repo.all()
  end

  # Out of each answer only the seats' totals plus the opening turn's cube
  # verdict (all `report.player_totals` needs to leave out the one decision
  # nobody could have made), because a whole response is hundreds of
  # kilobytes and a rating is two numbers out of it. Reaching into one is
  # the expensive part of both queries below -- about 0.25 ms a game on a
  # laptop, nearly all of it detoasting the stored answer -- so neither
  # asks for a row it will not use.
  @totals """
  jsonb_build_object(
           'players', r.response -> 'players',
           'turns', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
             'player', r.response -> 'turns' -> 0 -> 'player',
             'cube', r.response -> 'turns' -> 0 -> 'cube'))))\
  """

  # The seat-to-account join both queries are built on. The containment
  # test is the one `games_players_gin` is built on
  # (`oskol_players_jsonb(players) @> '[{"user_id": ...}]'`), byte for byte;
  # the LATERAL `unnest` beside it is only there to name *which* seat
  # matched, which the index cannot say.
  @seats """
  FROM games g
    JOIN LATERAL unnest(g.players) WITH ORDINALITY AS seat(p, ord)
      ON seat.p ->> 'user_id' = $1
    JOIN game_reviews r
      ON r.game_id = g.id AND r.status = 'done' AND r.response IS NOT NULL\
  """

  # What the recent list needs on top of the seats: which game of which
  # room, who was across the board, and how it ended. A rating needs none
  # of it, which is why the form's query does not pay for the two joins
  # that answer it.
  @graded_columns """
  g.id,
         g.slug,
         r.game_number,
         seat.ord - 1,
         seat.p ->> 'id',
         COALESCE(u.name, opp.p ->> 'name'),
         CASE WHEN last.line ->> 'kind' = 'game_over' THEN last.line ->> 'winner' END,
         CASE WHEN last.line ->> 'kind' = 'game_over'
              THEN COALESCE((last.line ->> 'points')::int, 0) ELSE 0 END,
         CASE WHEN last.line ->> 'kind' = 'game_over'
              THEN COALESCE(last.line ->> 'result', '') ELSE '' END,
         #{@totals},
         date_trunc('milliseconds', r.inserted_at)\
  """

  @graded_source """
  #{@seats}
    LEFT JOIN LATERAL (
      SELECT o.p
      FROM unnest(g.players) WITH ORDINALITY AS o(p, ord)
      WHERE o.ord <> seat.ord
      ORDER BY o.ord
      LIMIT 1
    ) AS opp ON TRUE
    LEFT JOIN users u ON u.id = NULLIF(opp.p ->> 'user_id', '')::uuid
    LEFT JOIN LATERAL (
      SELECT rec.entries -> -1 AS line
      FROM game_records rec
      WHERE rec.game_id = g.id AND rec.game_number = r.game_number
    ) AS last ON TRUE\
  """

  @doc """
  The graded games of one account, newest answer first, as a **rating**
  counts them: what the home's form, its chart and the career number beside
  a name are read from. The recent list counts rooms instead and reads
  `graded_rooms_for/3`.

  One statement, and nothing in it wakes a room or touches an action log.
  It is the seat-to-account join `bg-career-pr` describes: the rooms this
  account holds a seat in, their games the engine has answered for, and out
  of each answer only the seats' totals -- the same projection
  `rating_summaries/1` takes, because a whole response is hundreds of
  kilobytes and a rating is two numbers out of it.

  It asks for nothing else. This is the query that reads a whole career, up
  to a thousand games; naming the opponent and reading each game's result
  line costs two more joins a game (about 0.14 ms each on a laptop) and a
  rating uses neither.
  """
  def graded_for(user_id, limit)
      when is_binary(user_id) and is_integer(limit) and limit > 0 do
    {sql, params} = graded_for_sql(user_id, limit)
    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn [game_id, game_number, seat, totals, ended_at] ->
      %{
        game_id: game_id,
        game_number: game_number,
        seat: seat,
        totals: totals,
        ended_at: DateTime.from_naive!(ended_at, "Etc/UTC")
      }
    end)
  end

  @doc """
  The same rows counted in **rooms**: every graded game of the newest
  `rooms` rooms this account holds a seat in, the rooms newest answer first
  and each room's games together, newest game first inside.

  The recent list is one entry per room -- a match is the unit a player
  remembers -- so what a page counts is rooms, and a page boundary can
  never fall in the middle of a match. Each row also carries the little the
  page needs about the room itself: the format as it was stored, whether it
  is over, and who its row says won it.

  `before` pages: `{ended_at, room_id}` from the previous page's last room,
  compared as one row against the same two expressions the rooms are
  ordered on, so no room is shown twice or skipped. The moment is truncated
  to the millisecond on both sides, because that is the resolution a cursor
  survives the wire at: ordering on the stored microseconds while paging on
  milliseconds silently skips every room that shares a millisecond with the
  one a page stopped on. It only narrows what this caller already reaches
  -- the account is `user_id`, never the cursor's.
  """
  def graded_rooms_for(user_id, rooms, before \\ nil)
      when is_binary(user_id) and is_integer(rooms) and rooms > 0 do
    {sql, params} = graded_rooms_for_sql(user_id, rooms, before)
    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn row ->
      {game, [format, over, winners]} = Enum.split(row, 11)

      Map.merge(graded_row(game), %{
        format: format || "",
        over: over,
        winners: winners || []
      })
    end)
  end

  @doc """
  The local dates, on or after `since`, on which a game of this account's
  finished -- what the home's streak counts alongside a puzzle answered.

  It reads `game_records`: one row per finished game, written the moment
  the game ended and never rewritten, so a game the engine failed on still
  counts as a day this player played (a streak is about showing up, not
  about being graded). The seat join is the same containment test the
  index is built on, and `since` bounds it to the streak's own window.
  """
  def finished_days(user_id, %DateTime{} = since, tz)
      when is_binary(user_id) and is_binary(tz) do
    mine = [%{"user_id" => user_id}]

    sql = """
    SELECT DISTINCT ((rec.inserted_at AT TIME ZONE 'UTC') AT TIME ZONE $3)::date
    FROM games g
    JOIN game_records rec ON rec.game_id = g.id
    WHERE oskol_players_jsonb(g.players) @> $1
      AND rec.inserted_at >= $2
    """

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Repo, sql, [mine, DateTime.to_naive(since), tz])

    Enum.map(rows, &hd/1)
  end

  defp graded_row([
         game_id,
         slug,
         game_number,
         seat,
         player_id,
         opponent,
         winner,
         points,
         kind,
         totals,
         ended_at
       ]) do
    %{
      game_id: game_id,
      slug: slug,
      game_number: game_number,
      seat: seat,
      player_id: player_id,
      opponent: opponent,
      winner: winner,
      points: points,
      kind: kind,
      totals: totals,
      # A raw statement hands a timestamp back naive; every caller above
      # here works in UTC instants.
      ended_at: DateTime.from_naive!(ended_at, "Etc/UTC")
    }
  end

  @doc false
  # Kept as a builder so the regression test can EXPLAIN the exact statement
  # we send, with its parameters.
  def graded_for_sql(user_id, limit) do
    sql = """
    SELECT g.id,
           r.game_number,
           seat.ord - 1,
           #{@totals},
           date_trunc('milliseconds', r.inserted_at)
    #{@seats}
    WHERE oskol_players_jsonb(g.players) @> $2
    ORDER BY date_trunc('milliseconds', r.inserted_at) DESC, r.game_number DESC, g.id DESC
    LIMIT $3
    """

    {sql, [user_id, mine(user_id), limit]}
  end

  @doc false
  def graded_rooms_for_sql(user_id, rooms, before \\ nil) do
    {cursor_sql, cursor_params} =
      case before do
        nil ->
          {"", []}

        {%DateTime{} = at, room_id} ->
          {"HAVING (max(date_trunc('milliseconds', r.inserted_at)), g.id) < ($4, $5)",
           [DateTime.to_naive(at), room_id]}
      end

    # The rooms first, by their newest answer, and only then their games:
    # the limit counts rooms, so a match to seven is one line of the page
    # whether it ran two games or nine.
    sql = """
    WITH page AS (
      SELECT g.id AS room_id,
             max(date_trunc('milliseconds', r.inserted_at)) AS ended_at
      FROM games g
      JOIN LATERAL unnest(g.players) WITH ORDINALITY AS seat(p, ord)
        ON seat.p ->> 'user_id' = $1
      JOIN game_reviews r
        ON r.game_id = g.id AND r.status = 'done' AND r.response IS NOT NULL
      WHERE oskol_players_jsonb(g.players) @> $2
      GROUP BY g.id
      #{cursor_sql}
      ORDER BY ended_at DESC, room_id DESC
      LIMIT $3
    )
    SELECT #{@graded_columns},
           g.config ->> 'format',
           g.status = 'finished',
           g.winners
    #{@graded_source}
    JOIN page ON page.room_id = g.id
    WHERE oskol_players_jsonb(g.players) @> $2
    ORDER BY page.ended_at DESC, page.room_id DESC, r.game_number DESC
    """

    {sql, [user_id, mine(user_id), rooms] ++ cursor_params}
  end

  # Postgrex encodes a jsonb parameter itself: hand it the term, not text. A
  # text parameter through a `::jsonb` cast becomes a JSON *string*, which
  # no containment test ever matches.
  defp mine(user_id), do: [%{"user_id" => user_id}]

  @doc "One game's rendered analysis, or nil."
  def report(game_id, game_number) do
    from(r in Review,
      where: r.game_id == ^game_id and r.game_number == ^game_number,
      select: r.report
    )
    |> Repo.one()
  end

  @doc "Upsert one review row, whole: what is not passed is cleared."
  def save(game_id, game_number, status, attempts, response, error, report, turns)
      when status in ["pending", "done", "failed"] do
    now = DateTime.utc_now()

    Repo.insert!(
      %Review{
        game_id: game_id,
        game_number: game_number,
        status: status,
        attempts: attempts,
        response: response,
        error: error,
        report: report,
        turns: turns,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [
        set: [
          status: status,
          attempts: attempts,
          response: response,
          error: error,
          report: report,
          turns: turns,
          updated_at: now
        ]
      ],
      conflict_target: [:game_id, :game_number]
    )

    :ok
  end

  @doc """
  Write a fresh answer over an old one and owe the game its puzzles again,
  in one transaction: `save/8`, then `Oskol.Puzzles.reopen/2` (the
  extraction marker cleared, the `post_take_cube` sources dropped). One
  write on purpose: there is never a moment when the old answer is stored
  and the game is owed puzzles, which the live sweep would extract from
  the old answer. The backfill's, and nobody else's.
  """
  def replace(game_id, game_number, status, attempts, response, error, report, turns) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok = save(game_id, game_number, status, attempts, response, error, report, turns)
        :ok = Oskol.Puzzles.reopen(game_id, game_number)
      end)

    :ok
  end

  @doc """
  Charge engine calls against one row and say what happened, changing
  nothing else: the answer and the page stay. What the backfill writes on
  a `done` game it could not re-ask (the engine did not answer, or its
  answer could not be trusted) -- the page keeps what it had, and the row
  says why and stops being asked once its tries are spent.
  """
  def charge(game_id, game_number, attempts, error)
      when is_integer(attempts) and attempts >= 0 and (is_nil(error) or is_binary(error)) do
    from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
    |> Repo.update_all(
      set: [
        attempts: attempts,
        error: error && String.slice(error, 0, 500),
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  @doc """
  Every room with a graded game, oldest graded first, or the one named.
  The backfill's work list; which of a room's games are old is Gleam's to
  say from the stored answer, so this reads no body.
  """
  def rooms_reviewed(game_id \\ nil) do
    from(r in Review,
      where: r.status == "done" and not is_nil(r.response),
      group_by: r.game_id,
      order_by: [asc: min(r.inserted_at), asc: r.game_id],
      select: r.game_id
    )
    |> then(fn query ->
      if game_id, do: where(query, [r], r.game_id == ^game_id), else: query
    end)
    |> Repo.all()
  end

  @doc """
  Reviews that came back done with nothing in them, newest first: the shape
  a review takes when the replay produced no turn for a game that had one.

  What `close` did to an unlimited session between 2026-09-30 and its fix
  (the Aveline doc `bg-session-close-wiped-reviews`): ending the session
  read as a second game ending, the empty half of that overwrote the real
  answer, and the row was left `done` with `turns: 0`.

  A game that really had nothing to grade -- a resignation on the opening
  roll -- reads the same, and asking about one again costs a moment of
  engine time and comes back empty. That is the right trade for a sweep
  whose job is to miss nothing.

  `room` narrows to one room id.
  """
  def empty(limit, room \\ nil) when is_integer(limit) and limit > 0 do
    query =
      from(r in Review,
        where: r.status == "done" and r.turns == 0,
        order_by: [desc: r.updated_at],
        limit: ^limit,
        select: %{game_id: r.game_id, game_number: r.game_number, updated_at: r.updated_at}
      )

    query
    |> then(fn q -> if room, do: where(q, [r], r.game_id == ^room), else: q end)
    |> Repo.all()
  end

  @doc """
  Put one game's review back to pending with a full set of attempts and mark
  its room owed, so the queue builds it again. What a player's retry does to
  a failed game (`handlers/reviews.retry_json`), for an operator doing
  several.

  The answer and the page go with it, deliberately: what is there is the
  wrong answer, and `save/8` clears what it is not passed.
  """
  def rebuild(game_id, game_number) do
    save(game_id, game_number, "pending", 0, nil, nil, nil, nil)
    mark_analysis_owed(game_id)
    :ok
  end

  @doc "Fill in one legacy review's turn count without changing any other field."
  def backfill_turns(game_id, game_number, turns) when is_integer(turns) and turns >= 0 do
    from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
    |> Repo.update_all(set: [turns: turns])

    :ok
  end

  # ---------- Turns graded before the game ended ----------

  @doc """
  The sha256 of one review request body, in hex: the key a grade of that turn
  is stored and found under.

  Both sides of the cache hash the bytes Gleam built and nothing else, so
  nothing between here and there can reorder a key and turn a hit into a miss.
  """
  def turn_key(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  @doc """
  The grades stored for these request bodies, in the order they were asked:
  the engine's reply where that exact question has been answered already, nil
  where it has not.

  One query for the whole game, not one per turn: a match is sixty turns and
  a review is not worth sixty round trips.
  """
  def turn_grades(game_id, game_number, bodies) when is_list(bodies) do
    keys = Enum.map(bodies, &turn_key/1)

    found =
      from(t in TurnGrade,
        where:
          t.game_id == ^game_id and t.game_number == ^game_number and
            t.turn_key in ^Enum.uniq(keys),
        select: {t.turn_key, t.response}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(keys, &Map.get(found, &1))
  end

  @doc """
  Store one turn's grade, unless that question already has an answer.

  Never an update: a stored grade is the engine's answer to a question that
  cannot change, so a second cast about the same turn has nothing to say.
  """
  def save_turn_grade(game_id, game_number, body, response)
      when is_binary(body) and is_map(response) do
    Repo.insert_all(
      TurnGrade,
      [
        %{
          game_id: game_id,
          game_number: game_number,
          turn_key: turn_key(body),
          response: response,
          inserted_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:game_id, :game_number, :turn_key]
    )

    :ok
  end

  @doc "Is this exact question already answered? What the Grader asks before spending engine time."
  def turn_graded?(game_id, game_number, body) when is_binary(body) do
    from(t in TurnGrade,
      where:
        t.game_id == ^game_id and t.game_number == ^game_number and
          t.turn_key == ^turn_key(body)
    )
    |> Repo.exists?()
  end

  @doc """
  Drop a game's grades: they are spent the moment its own answer is written.
  """
  def forget_turn_grades(game_id, game_number) do
    from(t in TurnGrade, where: t.game_id == ^game_id and t.game_number == ^game_number)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Drop grades older than `days`, and say how many.

  What is left over is a room nobody finished: its turns were graded and no
  job will ever come to spend them. Nothing here is durable, so the only
  question is how long a cache miss stays possible, and a week is longer than
  any game.
  """
  def sweep_turn_grades(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
    {count, _} = Repo.delete_all(from(t in TurnGrade, where: t.inserted_at < ^cutoff))
    count
  end

  # ---------- The record ----------

  @doc "Every stored record row of a room, by game number."
  def records(game_id) do
    from(r in Record, where: r.game_id == ^game_id, order_by: r.game_number)
    |> Repo.all()
  end

  @doc """
  One game's record entries, or nil. What a caller that wants a single
  game's result should read: the whole-room `records/1` carries every
  finished game's every line, and a memory line needs one of them.
  """
  def record_entries(game_id, game_number) do
    from(r in Record,
      where: r.game_id == ^game_id and r.game_number == ^game_number,
      select: r.entries
    )
    |> Repo.one()
  end

  @doc """
  One turn of one game's rendered analysis, projected in the database.

  A report is hundreds of kilobytes and a caller that wants to know which
  line of the record a turn sits on wants three integers out of it. The
  path is taken by PostgreSQL, so only that turn's object crosses the wire
  and only it is parsed. `turn` counts from 1, as the review numbers them.
  """
  def report_turn(game_id, game_number, turn) when is_integer(turn) and turn >= 1 do
    from(r in Review,
      where: r.game_id == ^game_id and r.game_number == ^game_number,
      select: fragment("? #> ARRAY['turns', ?]", r.report, ^Integer.to_string(turn - 1))
    )
    |> Repo.one()
  end

  def report_turn(_game_id, _game_number, _turn), do: nil

  @doc "The record index, without any of the per-turn bodies."
  def record_numbers(game_id) do
    from(r in Record,
      where: r.game_id == ^game_id,
      order_by: r.game_number,
      select: r.game_number
    )
    |> Repo.all()
  end

  @doc """
  Write rows for a room's finished games: `[{game_number, entries}]`. A game
  already stored is left exactly as it is — a finished game never changes,
  and rewriting it would only cost writes.
  """
  def save_records(game_id, rows, through, generation) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn {number, entries} ->
        %{
          game_id: game_id,
          game_number: number,
          entries: entries,
          finished: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transaction(fn ->
      Repo.insert_all(Record, entries,
        on_conflict: :nothing,
        conflict_target: [:game_id, :game_number]
      )

      # Use the snapshot that produced the rows. A game may have ended
      # during replay; reading its new marker now would hide missing rows.
      # An older concurrent backfill may add rows, but cannot rewind this.
      from(g in Oskol.Persistence.Game,
        where: g.id == ^game_id,
        update: [
          set: [
            records_through: fragment("GREATEST(COALESCE(?, 0), ?)", g.records_through, ^through),
            records_generation:
              fragment("GREATEST(COALESCE(?, 0), ?)", g.records_generation, ^generation)
          ]
        ]
      )
      |> Repo.update_all([])
    end)

    :ok
  end

  @doc """
  What started a room, without its log: the setup, its seats and whether it
  is over. Nothing here reads `game_actions`.
  """
  def setup(game_id) do
    case Repo.get(Oskol.Persistence.Game, game_id) do
      %{seed: seed, status: status} = game when is_integer(seed) and status != "waiting" ->
        game

      _ ->
        nil
    end
  end

  @doc """
  Note that this room has a game that ended and may owe an analysis.

  Written before the queue is asked, so a restart between the two cannot
  lose the fact. `sweep_owed/0` is what picks it up again.
  """
  def mark_analysis_owed(game_id) do
    from(g in Oskol.Persistence.Game, where: g.id == ^game_id)
    |> Repo.update_all(set: [analysis_owed: true, analysis_owed_at: DateTime.utc_now()])

    :ok
  end

  @doc "When this room's note was last made, or nil if it owes nothing."
  def analysis_owed_at(game_id) do
    from(g in Oskol.Persistence.Game,
      where: g.id == ^game_id and g.analysis_owed == true,
      select: g.analysis_owed_at
    )
    |> Repo.one()
  end

  @doc """
  This room owes nothing, as far as the job that just finished could see.

  Only a note no newer than `seen` is cleared. A game that ends while a job
  is running makes a fresh note, and that one has to survive: the running
  job read the log before that game existed and cannot have analysed it.
  """
  def clear_analysis_owed(game_id, seen) do
    query =
      case seen do
        nil ->
          from(g in Oskol.Persistence.Game,
            where: g.id == ^game_id and is_nil(g.analysis_owed_at)
          )

        %DateTime{} ->
          from(g in Oskol.Persistence.Game,
            where:
              g.id == ^game_id and
                (is_nil(g.analysis_owed_at) or g.analysis_owed_at <= ^seen)
          )
      end

    {_, _} = Repo.update_all(query, set: [analysis_owed: false])
    :ok
  end

  @doc "Rooms still marked as owing an analysis, oldest first."
  def rooms_owed_analysis do
    from(g in Oskol.Persistence.Game,
      where: g.analysis_owed == true,
      order_by: [asc: g.updated_at],
      select: g.id
    )
    |> Repo.all()
  end

  @doc "The completed-game work marker; ordinary actions leave it alone."
  def record_generation(%{analysis_owed_at: nil}), do: 0
  def record_generation(%{analysis_owed_at: at}), do: DateTime.to_unix(at, :microsecond)

  # ---------- The log ----------

  @doc """
  A started game's setup, seats and log, or nil. Payloads come back as the
  JSON they were stored as.
  """
  def log(game_id) do
    case Oskol.Persistence.fetch(game_id) do
      {:ok, %{seed: seed, status: status} = game, actions}
      when is_integer(seed) and status != "waiting" ->
        %{game: game, actions: actions}

      _ ->
        nil
    end
  end

  # ---------- The engine ----------

  @doc """
  Ask the engine whether it is there: `GET /health`, down the same road a
  review takes — same base URL, same IPv6 setting, same connect timeout — so
  what this answers is what a review would meet, not something adjacent.

  `{:ok, ms}` when it answers 200, `{:error, reason}` otherwise. The receive
  timeout is seconds rather than the review's twenty minutes: a health check
  that waits is a health check nobody reads. A stopped Fly machine starts on
  the first request and may spend a few of those seconds waking, which reads
  as down and then up, correctly — it was not there when asked.

  Never raises.
  """
  def health(receive_timeout \\ 5_000) do
    config = Application.get_env(:oskol, :analysis, [])
    url = String.trim_trailing(Keyword.get(config, :url, "http://localhost:18082"), "/")

    options =
      [
        url: url <> "/health",
        receive_timeout: receive_timeout,
        connect_options: [
          timeout: 5_000,
          transport_opts: if(Keyword.get(config, :inet6, false), do: [inet6: true], else: [])
        ],
        retry: false
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    started = System.monotonic_time(:millisecond)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, System.monotonic_time(:millisecond) - started}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Ask the engine one question and hand the answer back as it came: the route
  under the same base URL a review takes, a JSON body in, the response body
  out. `{:ok, body}` on a 200, `{:error, sentence}` otherwise. Never raises.

  This is what a bot seat thinks through (`Oskol.Game.Bot`), and the receive
  timeout is seconds rather than a review's twenty minutes: nobody at a table
  waits that long, and a think that came back empty is tried again.
  """
  def ask(route, body, receive_timeout) when is_binary(route) and is_binary(body) do
    config = Application.get_env(:oskol, :analysis, [])
    url = String.trim_trailing(Keyword.get(config, :url, "http://localhost:18082"), "/")

    options =
      [
        url: url <> route,
        body: body,
        headers: [{"content-type", "application/json"}],
        receive_timeout: receive_timeout,
        connect_options: [
          timeout: 15_000,
          transport_opts: if(Keyword.get(config, :inet6, false), do: [inet6: true], else: [])
        ],
        # The caller owns retries: it is counting the failures for the game.
        retry: false,
        # The body is read in Gleam, which wants the text.
        decode_body: false
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    posted(options)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  POST a review request (JSON text) to the engine. `{:ok, body}` on a 200,
  `{:error, reason}` otherwise — a status and the engine's detail, a
  timeout, a refused connection. Never raises.
  """
  def request(body) when is_binary(body) do
    config = Application.get_env(:oskol, :analysis, [])
    url = String.trim_trailing(Keyword.get(config, :url, "http://localhost:18082"), "/")

    options =
      [
        url: url <> "/backgammon/review",
        body: body,
        headers: [{"content-type", "application/json"}],
        receive_timeout: Keyword.get(config, :receive_timeout, :timer.minutes(20)),
        connect_options: [
          timeout: 15_000,
          transport_opts: if(Keyword.get(config, :inet6, false), do: [inet6: true], else: [])
        ],
        # The queue owns retries (at most twice, with backoff).
        retry: false,
        # The body is stored verbatim and read in Gleam.
        decode_body: false
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    posted(options)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Every request to the engine is made from its own process, and that is the
  # whole point of this function.
  #
  # Finch delivers a reply to whoever asked, as messages. A request that times
  # out is abandoned by Req, but its reply still arrives and sits in that
  # process's mailbox. The next request made from the same process reads the
  # *old* reply and dies on it -- in production, on 2026-09-30,
  # `no case clause matching: {:status, #Reference<...>, 200}`.
  #
  # That is how one slow think ended a game. The bot retries in the process it
  # first asked in, so attempt 1 timing out poisoned attempt 2, which crashed,
  # and attempt 3 timed out behind it. Sage gave up and offered a resignation,
  # and declining it started the same three failures over. The engine answered
  # 200 to every one of those requests.
  #
  # A mailbox goes with its process, so here an abandoned reply is abandoned
  # rather than left lying for the next caller.
  defp posted(options) do
    timeout = Keyword.fetch!(options, :receive_timeout)

    # Linked, deliberately. The caller owns this request: a queue task killed
    # mid-review must take its request down with it (the recovery tests kill
    # one on purpose), and a request that outlived the job that wanted it
    # would be work nobody is waiting for. Linking also carries `$callers`,
    # which is how the test stub is found.
    task = Task.async(fn -> Req.post(options) end)

    # Req owns the timeout and answers first whenever it can; this is only the
    # backstop for a task that never answers at all, so it is the request's own
    # budget and a little more.
    case Task.yield(task, timeout + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %Req.Response{status: 200, body: body}}} when is_binary(body) ->
        {:ok, body}

      {:ok, {:ok, %Req.Response{status: status, body: body}}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 500)}"}

      {:ok, {:error, exception}} ->
        {:error, Exception.message(exception)}

      {:exit, reason} ->
        {:error, "the request did not finish: #{inspect(reason)}"}

      nil ->
        {:error, "timeout"}
    end
  end
end
