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

      timestamps(type: :utc_datetime_usec)
    end
  end

  # ---------- Storage ----------

  @doc "Every stored review of a room, by game number."
  def stored(game_id) do
    from(r in Review, where: r.game_id == ^game_id, order_by: r.game_number)
    |> Repo.all()
  end

  @doc "Upsert one review row."
  def save(game_id, game_number, status, attempts, response, error)
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
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [
        set: [
          status: status,
          attempts: attempts,
          response: response,
          error: error,
          updated_at: now
        ]
      ],
      conflict_target: [:game_id, :game_number]
    )

    :ok
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
