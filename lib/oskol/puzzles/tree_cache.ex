defmodule Oskol.Puzzles.TreeCache do
  @moduledoc """
  The move tree of a puzzle, kept once it has been worked out.

  A tree is a pure function of the stored question, and a stored question is
  never rewritten, so a hit is always right and the store never has to be
  invalidated. It is not a source of anything: forgetting an entry costs one
  rebuild, which is the ~10 ms a normal position takes.

  Bounded, and bluntly so. The table is a dictionary of ids the site is
  currently handing out; when it passes `max_entries` it is emptied and
  fills again. There is no LRU because there is nothing to gain from one: a
  practice session walks a handful of puzzles, the pages that matter are
  whatever is being shared today, and the cost of being wrong about which
  entry to drop is one build.

  The table is public and written from the request process, so a read costs
  no message. The GenServer exists to own the table, not to serve it.
  """

  use GenServer

  @table :oskol_puzzle_trees
  # About 100 KB apiece at the very worst, and a typical one is a few KB,
  # so this is tens of megabytes in the pathological case and well under
  # one in practice.
  @max_entries 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The tree already worked out for this puzzle, as JSON text, or nil."
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, text}] -> text
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Keep this one. Silently does nothing if the table is not up."
  def put(id, text) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {id, text})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
