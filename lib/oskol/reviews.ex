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

  @doc """
  The graded games of one account, newest answer first: what the home's
  form, its chart and its recent list are all read from.

  One statement, and nothing in it wakes a room or touches an action log.
  It is the seat-to-account join `bg-career-pr` describes: the rooms this
  account holds a seat in, their games the engine has answered for, and out
  of each answer only the seats' totals -- the same projection
  `rating_summaries/1` takes, because a whole response is hundreds of
  kilobytes and a rating is two numbers out of it.

  The containment test is the one `games_players_gin` is built on
  (`oskol_players_jsonb(players) @> '[{"user_id": ...}]'`), byte for byte;
  the LATERAL `unnest` beside it is only there to name *which* seat matched,
  which the index cannot say.

  `before` pages: `{ended_at, game_number, game_id}` from the previous
  page's last row, compared as one row against the same three expressions
  the order is on, so no row is shown twice or skipped. The moment is
  truncated to the millisecond on both sides, because that is the
  resolution a cursor survives the wire at: ordering on the stored
  microseconds while paging on milliseconds silently skips every row that
  shares a millisecond with the one a page stopped on. It only narrows what
  this caller already reaches -- the account is `user_id`, never the
  cursor's.
  """
  def graded_for(user_id, limit, before \\ nil)
      when is_binary(user_id) and is_integer(limit) and limit > 0 do
    {sql, params} = graded_for_sql(user_id, limit, before)
    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn [
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
                      ] ->
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
    end)
  end

  @doc false
  # Kept as a builder so the regression test can EXPLAIN the exact statement
  # we send, with its parameters.
  def graded_for_sql(user_id, limit, before \\ nil) do
    # Postgrex encodes a jsonb parameter itself: hand it the term, not
    # text. A text parameter through a `::jsonb` cast becomes a JSON
    # *string*, which no containment test ever matches.
    mine = [%{"user_id" => user_id}]

    {cursor_sql, cursor_params} =
      case before do
        nil ->
          {"", []}

        {%DateTime{} = at, game_number, game_id} ->
          {"AND (date_trunc('milliseconds', r.inserted_at), r.game_number, g.id) < ($4, $5, $6)",
           [DateTime.to_naive(at), game_number, game_id]}
      end

    sql = """
    SELECT g.id,
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
           jsonb_build_object(
             'players', r.response -> 'players',
             'turns', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
               'player', r.response -> 'turns' -> 0 -> 'player',
               'cube', r.response -> 'turns' -> 0 -> 'cube')))),
           date_trunc('milliseconds', r.inserted_at)
    FROM games g
    JOIN LATERAL unnest(g.players) WITH ORDINALITY AS seat(p, ord)
      ON seat.p ->> 'user_id' = $1
    JOIN game_reviews r
      ON r.game_id = g.id AND r.status = 'done' AND r.response IS NOT NULL
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
    ) AS last ON TRUE
    WHERE oskol_players_jsonb(g.players) @> $2
      #{cursor_sql}
    ORDER BY date_trunc('milliseconds', r.inserted_at) DESC, r.game_number DESC, g.id DESC
    LIMIT $3
    """

    {sql, [user_id, mine, limit] ++ cursor_params}
  end

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

  @doc "Fill in one legacy review's turn count without changing any other field."
  def backfill_turns(game_id, game_number, turns) when is_integer(turns) and turns >= 0 do
    from(r in Review, where: r.game_id == ^game_id and r.game_number == ^game_number)
    |> Repo.update_all(set: [turns: turns])

    :ok
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

    case Req.post(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 500)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
