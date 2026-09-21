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
  Write rows for a room's finished games: `[{game_number, entries}]`. A game
  already stored is left exactly as it is — a finished game never changes,
  and rewriting it would only cost writes.
  """
  def save_records(game_id, rows) do
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

    Repo.insert_all(Record, entries,
      on_conflict: :nothing,
      conflict_target: [:game_id, :game_number]
    )

    # Which log these rows were made from. A read compares it with the log
    # the room has now: shorter means games have been played since and the
    # rows are short of them, equal means there is nothing to go and look
    # for. Without it a match settled at its first game would keep serving
    # one game forever.
    mark_records_through(game_id)

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
          from(g in Oskol.Persistence.Game, where: g.id == ^game_id)

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

  @doc "Mark a room's records as made from the log it has right now."
  def mark_records_through(game_id) do
    from(g in Oskol.Persistence.Game, where: g.id == ^game_id)
    |> Repo.update_all(set: [records_through: log_length(game_id)])

    :ok
  end

  @doc "How many steps the room's action log holds."
  def log_length(game_id) do
    from(a in "game_actions", where: a.game_id == ^game_id, select: count(a.index))
    |> Repo.one()
    |> Kernel.||(0)
  end

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
