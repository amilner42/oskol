defmodule Oskol.Reviews.Payload do
  @moduledoc """
  The reviews answer, built once and kept.

  `GET /papi/.../reviews` answers with a whole match's analysis. Building it
  replays the room's action log and encodes every graded turn of every game:
  seconds of work and megabytes of intermediate data for a long match. The
  page asks for it while an analysis is still on its way, so the same answer
  is built over and over, and two readers (or one reader and a reload) build
  it at the same time.

  So it is built once per version of the room and kept in an ETS table, and
  the build runs in this process, which means never more than one at a time
  no matter how many readers arrive. A version is what the answer is made
  of: how many reviews the room has, when the newest of them was written,
  and how long its action log is. Anything that could change the answer
  changes one of those, so there is nothing to invalidate by hand.

  The cache is memory, not truth: it is dropped on restart and holds at most
  `@keep` rooms, the least recently read going first.
  """

  use GenServer

  import Ecto.Query

  alias Oskol.Repo

  @table :reviews_payload
  @keep 50
  @build_timeout :timer.seconds(60)

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc """
  The answer for `game_id`, built by `build` only if this version of the room
  has not been built already. `build` is a zero-argument function returning
  the same `{:ok, json}` / `{:error, term}` the handler does; only `{:ok, _}`
  is kept.
  """
  def fetch(game_id, build) when is_binary(game_id) and is_function(build, 0) do
    version = version(game_id)

    case lookup(game_id, version) do
      {:ok, json} ->
        {:ok, json}

      :miss ->
        GenServer.call(__MODULE__, {:build, game_id, version, build}, @build_timeout)
    end
  catch
    :exit, {:timeout, _} ->
      # The build is someone else's and still running: better a slow answer
      # refused than a queue of duplicate builds behind it.
      {:error, :busy}
  end

  @doc "Forget what is kept for a room (tests, and anything that writes behind our back)."
  def forget(game_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, game_id)
    :ok
  end

  # ---------- The version a built answer belongs to ----------

  defp version(game_id) do
    # Neither table has a surrogate key: a review is one row per (game_id,
    # game_number) and an action one per (game_id, index).
    reviews =
      from(r in "game_reviews",
        where: r.game_id == ^game_id,
        select: {count(r.game_number), max(r.updated_at)}
      )
      |> Repo.one()

    actions =
      from(a in "game_actions", where: a.game_id == ^game_id, select: max(a.index))
      |> Repo.one()

    {reviews, actions}
  end

  defp lookup(game_id, version) do
    case :ets.whereis(@table) != :undefined && :ets.lookup(@table, game_id) do
      [{^game_id, ^version, json, _read_at}] ->
        :ets.update_element(@table, game_id, {4, System.monotonic_time()})
        {:ok, json}

      _ ->
        :miss
    end
  end

  # ---------- The one process that builds ----------

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:build, game_id, version, build}, _from, state) do
    # Someone may have built it while this call waited its turn.
    case lookup(game_id, version) do
      {:ok, json} ->
        {:reply, {:ok, json}, state}

      :miss ->
        result = build.()

        case result do
          {:ok, json} ->
            :ets.insert(@table, {game_id, version, json, System.monotonic_time()})
            trim()

          _ ->
            :ok
        end

        {:reply, result, state}
    end
  end

  defp trim do
    if :ets.info(@table, :size) > @keep do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, _v, _json, read_at} -> read_at end)
      |> Enum.take(:ets.info(@table, :size) - @keep)
      |> Enum.each(fn {id, _v, _json, _read_at} -> :ets.delete(@table, id) end)
    end
  end
end
