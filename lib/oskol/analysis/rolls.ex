defmodule Oskol.Analysis.Rolls do
  @moduledoc """
  Per-roll grids: the engine call, and the rows that mean it is made once.

  `oskol/handlers/analysis.rolls_json` decides everything -- whether the
  position can be asked, which boards, on which cube, whose budget it costs,
  what each refusal says -- and hands this module the exact request bodies
  Gleam built. Nothing here looks inside one.

  **Answered in the request.** A grid is about 0.2 s of engine time (measured
  over the real path, Oskol -> Fly -> tailnet -> the desktop: 0.31-0.37 s for
  one, 0.38-0.52 s for a batch of two), so there is no job, no queue and
  nothing for a page to poll. Two boards go in one `/backgammon/batch` of
  `rolls` items rather than two round trips.

  **Behind the asker's circuit all the same.** The line is not what matters
  here -- a grid does not wait -- but the circuit is: a desktop asleep behind
  a tailnet must be asked once, not once per keen player. The handler reads
  the circuit before asking (`Asker.asking/1`), and a failure here opens it
  (`Asker.engine_failed/1`) exactly as a failed ask does.

  **Cached by the request's bytes**, as a turn's grade is (`turn_grades`): the
  sha256 of the body Gleam built, so a grid is found by the question it
  answers and by nothing else -- the board, the cube, the match score and the
  level are all in those bytes. A row is **never rewritten**: the same
  question has one answer. A cached key costs no engine time and no budget,
  which is why the lookup is its own capability.

  The rows are a cache and nothing else: losing the table costs 0.2 s a grid.
  They are swept with the turn grades' keep-days (`Asker`'s hourly sweep).

  Config `config :oskol, Oskol.Analysis.Rolls, timeout_ms:` -- seconds, not a
  review's twenty minutes, because somebody is waiting on this reply.
  """

  import Ecto.Query
  require Logger

  alias Oskol.Repo
  alias Oskol.Reviews

  @one_route "/backgammon/rolls"
  @batch_route "/backgammon/batch"
  @default_timeout_ms 15_000

  defmodule Grid do
    @moduledoc """
    One board's per-roll grid, as the engine answered it.

    Keyed by the sha256 of the request body, so the row is the answer to that
    exact question -- board, cube, match score and depth -- and to no other.
    """
    use Ecto.Schema

    @primary_key false
    schema "roll_grids" do
      field(:grid_key, :string, primary_key: true)
      field(:answer, :map)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  @doc """
  The grids stored for these request bodies, in the order they were asked
  about, as Gleam's `List(Option(String))`: the engine's answer where that
  exact board is answered already, `:none` where it is not.

  One query for the whole request, and a body repeated in it is looked up
  once.
  """
  def cached(bodies) when is_list(bodies) do
    keys = Enum.map(bodies, &key/1)

    found =
      from(g in Grid, where: g.grid_key in ^Enum.uniq(keys), select: {g.grid_key, g.answer})
      |> Repo.all()
      |> Map.new()

    Enum.map(keys, fn key ->
      case Map.get(found, key) do
        nil -> :none
        answer -> {:some, Jason.encode!(answer)}
      end
    end)
  end

  @doc """
  Ask the engine for these grids and keep each answer, in the order asked.

  One body is one `POST /backgammon/rolls`; more than one is a `/batch` of
  `rolls` items, which the engine answers in order. `{:ok, [json]}`, or
  `{:error, {:rolls_refused, detail}}` when the engine read the boards and
  would not answer them (a 4xx, which a player-built position can provoke),
  or `{:error, {:rolls_unreachable, seconds}}` when the engine itself is in
  trouble -- and then the circuit is open for those seconds.
  """
  def ask([]), do: {:ok, []}

  def ask(bodies) when is_list(bodies) do
    {route, body} = request(bodies)

    case Reviews.ask_status(route, body, timeout_ms()) do
      {:ok, response} ->
        kept(bodies, response)

      {:rejected, status, detail} ->
        Logger.warning("rolls refused by the engine (HTTP #{status}): #{detail}")
        {:error, {:rolls_refused, detail}}

      {:error, reason} ->
        {:error, {:rolls_unreachable, Oskol.Analysis.Asker.engine_failed(reason)}}
    end
  end

  # One board goes to the grid route; several ride one batch, whose results
  # come back in the order the items were sent.
  defp request([body]), do: {@one_route, body}

  defp request(bodies) do
    items = Enum.map(bodies, fn body -> %{kind: "rolls", request: Jason.Fragment.new(body)} end)
    {@batch_route, Jason.encode!(%{items: items})}
  end

  defp kept(bodies, response) do
    with {:ok, answers} <- answers(bodies, response) do
      Enum.zip(bodies, answers)
      |> Enum.each(fn {body, answer} -> store(body, answer) end)

      {:ok, Enum.map(answers, &Jason.encode!/1)}
    end
  end

  # An answer that does not read as one grid per board is the engine not
  # understanding the question, which is the same thing to a caller as the
  # engine being unreachable: nothing is stored.
  defp answers(bodies, response) do
    decoded = Jason.decode(response)
    count = length(bodies)

    case {decoded, count} do
      {{:ok, %{"rows" => _} = grid}, 1} ->
        {:ok, [grid]}

      {{:ok, %{"results" => results}}, _} when is_list(results) ->
        if length(results) == count and Enum.all?(results, &grid?/1),
          do: {:ok, results},
          else: malformed(count)

      _ ->
        malformed(count)
    end
  end

  defp grid?(%{"rows" => rows}) when is_list(rows), do: true
  defp grid?(_), do: false

  defp malformed(count) do
    Logger.warning("the engine answered #{count} grids with something else")
    {:error, {:rolls_unreachable, 1}}
  end

  # Never an update: the same question has one answer, and a second ask about
  # it (two players pressing at once) has nothing to say.
  defp store(body, answer) do
    Repo.insert_all(
      Grid,
      [%{grid_key: key(body), answer: answer, inserted_at: DateTime.utc_now()}],
      on_conflict: :nothing,
      conflict_target: [:grid_key]
    )

    :ok
  end

  @doc """
  The sha256 of one grid request body, in hex: the key its answer is stored
  and found under. `Reviews.turn_key/1`'s rule, over these bytes.
  """
  def key(body) when is_binary(body), do: Reviews.turn_key(body)

  @doc """
  Drop grids older than `days`, and say how many. A grid is a pure function of
  its question, so the only cost of forgetting one is asking again.
  """
  def sweep(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
    {count, _} = Repo.delete_all(from(g in Grid, where: g.inserted_at < ^cutoff))
    count
  end

  defp timeout_ms do
    Application.get_env(:oskol, __MODULE__, []) |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end
end
