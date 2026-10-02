defmodule Oskol.Analysis.Asker do
  @moduledoc """
  Puts the analysis board's positions to the engine, a few at a time.

  `oskol/handlers/analysis` decides everything about an ask -- whether the
  position can be asked, whether its row already answers it, whose budget it
  is charged to, what each refusal says -- and hands this process an `Ask`
  (`src/oskol/caps/analysis.gleam`) only for a key that needs the engine.
  What is left here is the line:

    * **One job per key.** Jobs are keyed by the puzzle key, so a second ask
      for a key queued or in flight joins it.
    * **`in_flight` at once (2), `waiting` more (20).** A full line answers
      `:full`, which the handler turns into a 429. Two at once leaves a game
      review's pool whole.
    * **The circuit**, as `Oskol.Reviews.Grader`'s: an engine that fails is
      not asked again for `circuit_ms` (60 s). Every ask in that time is
      answered `{:down, seconds}` at once (a 503), and the jobs already
      waiting fail with the same sentence, so a sleeping desktop is asked
      once and not once per keen player.

  A task asks `Oskol.Reviews.ask/3` and hands the answer to the Gleam
  `store`, which writes the puzzle (or refuses an answer it cannot trust).
  A task that crashes is a failure for its key, never for this process.

  **Outcomes live in a public ETS table** (`{key, status, payload, at_ms}`)
  for ten minutes, which is what `GET /papi/analysis/:key` reads, along with
  the circuit and the line's length (`asking/1` reads them without a call).
  A restart forgets them all: a page polling a key that was in flight gets
  a 404 and asks again, and a key that was answered is answered from its
  puzzle row anyway.

  Config `config :oskol, Oskol.Analysis.Asker, enabled:, in_flight:,
  waiting:, circuit_ms:, ask_timeout_ms:`. Off in tests (jobs are taken and
  never asked) unless a test turns it on.
  """

  use GenServer
  require Logger

  alias Oskol.Gleam.CtxBuilder
  alias Oskol.Reviews

  @table __MODULE__
  @task_supervisor Oskol.Analysis.AskerSupervisor
  @keep_ms :timer.minutes(10)
  @sweep_ms :timer.minutes(1)
  @route "/backgammon/review"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------- Reads (no call) ----------

  @doc """
  Where the asker stands for a key, as Gleam's `caps/analysis.Asker`:
  `:asked` (queued or in flight), `{:down, seconds}`, `:full`, or `:free`.
  A read of the table, so a POST never waits on this process to decide.
  """
  def asking(key) when is_binary(key) do
    cond do
      pending?(key) -> :asked
      (left = circuit_left()) > 0 -> {:down, div(left + 999, 1000)}
      waiting() >= config(:waiting, 20) -> :full
      true -> :free
    end
  rescue
    ArgumentError -> :free
  end

  @doc """
  What the asker remembers of a key, as Gleam's `Option(caps/analysis.Job)`.
  """
  def job(key) when is_binary(key) do
    case lookup(key) do
      {^key, :pending, _, _} -> {:some, :job_pending}
      {^key, :done, id, _} -> {:some, {:job_done, id}}
      {^key, :failed, message, _} -> {:some, {:job_failed, message}}
      nil -> :none
    end
  end

  # ---------- Calls ----------

  @doc """
  Take one ask: `:asked` when it is queued or joins the same key already in
  hand, `:full` or `{:down, seconds}` when it is not taken.
  """
  def submit({:ask, key, _ids, _kind, _question, _body} = ask) when is_binary(key) do
    GenServer.call(__MODULE__, {:submit, ask})
  catch
    :exit, _ -> :full
  end

  @doc "Wait until nothing is queued or in flight. For tests."
  def await_idle(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :await_idle, timeout)
  end

  @doc "Forget every job, outcome and open circuit. For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ---------- Server ----------

  @impl true
  def init(_opts) do
    ensure_table()
    :ets.delete_all_objects(@table)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, fresh()}
  end

  defp fresh do
    %{queue: :queue.new(), running: %{}, open_until: nil, waiters: []}
  end

  @impl true
  def handle_call({:submit, {:ask, key, _, _, _, _} = ask}, _from, state) do
    cond do
      pending?(key) ->
        {:reply, :asked, state}

      circuit_open?(state) ->
        {:reply, {:down, div(circuit_left() + 999, 1000)}, state}

      :queue.len(state.queue) >= config(:waiting, 20) ->
        {:reply, :full, state}

      true ->
        :ets.insert(@table, {key, :pending, nil, now_ms()})
        state = start_next(%{state | queue: :queue.in(ask, state.queue)})
        {:reply, :asked, counted(state)}
    end
  end

  def handle_call(:await_idle, from, state) do
    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(Map.keys(state.running), &Process.demonitor(&1, [:flush]))
    :ets.delete_all_objects(@table)
    {:reply, :ok, counted(fresh())}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)
    cutoff = now_ms() - @keep_ms

    :ets.select_delete(@table, [
      {{:"$1", :"$2", :_, :"$3"},
       [{:is_binary, :"$1"}, {:"=/=", :"$2", :pending}, {:<, :"$3", cutoff}], [true]}
    ])

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {key, running} ->
        state = %{state | running: running}
        {:noreply, state |> finished(key, result) |> start_next() |> counted() |> idle_now()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {key, running} ->
        Logger.warning("analysis ask crashed: #{inspect(reason)}")
        fail(key, failed_sentence())

        {:noreply, %{state | running: running} |> start_next() |> counted() |> idle_now()}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finished(state, key, {:done, id}) do
    :ets.insert(@table, {key, :done, id, now_ms()})
    state
  end

  defp finished(state, key, {:failed, reason}) do
    Logger.warning("analysis answer not kept: #{reason}")
    fail(key, failed_sentence())
    state
  end

  # The engine did not answer. Not asked again for a while, and every job
  # waiting for it is told so now rather than in a minute.
  defp finished(state, key, {:engine_failed, reason}) do
    circuit_ms = config(:circuit_ms, 60_000)
    Logger.warning("analysis paused for #{div(circuit_ms, 1000)}s: #{reason}")
    down = engine_down_sentence()
    fail(key, down)

    state.queue
    |> :queue.to_list()
    |> Enum.each(fn {:ask, waiting, _, _, _, _} -> fail(waiting, down) end)

    until = System.monotonic_time(:millisecond) + circuit_ms
    :ets.insert(@table, {{:meta, :circuit}, until, nil, 0})
    %{state | queue: :queue.new(), open_until: until}
  end

  defp fail(key, message), do: :ets.insert(@table, {key, :failed, message, now_ms()})

  defp start_next(state) do
    if enabled?() and map_size(state.running) < config(:in_flight, 2) and
         not circuit_open?(state) do
      case :queue.out(state.queue) do
        {{:value, {:ask, key, _, _, _, _} = ask}, queue} ->
          task = Task.Supervisor.async_nolink(@task_supervisor, fn -> run(ask) end)
          start_next(%{state | queue: queue, running: Map.put(state.running, task.ref, key)})

        {:empty, _} ->
          state
      end
    else
      state
    end
  end

  # One ask, in its own task: the engine, then Gleam's word on the answer.
  defp run({:ask, _key, _ids, _kind, _question, body} = ask) do
    case Reviews.ask(@route, body, config(:ask_timeout_ms, 60_000)) do
      {:ok, response} ->
        case :oskol@handlers@analysis.store(CtxBuilder.build(), ask, response) do
          {:ok, id} -> {:done, id}
          {:error, reason} -> {:failed, reason}
        end

      {:error, reason} ->
        {:engine_failed, reason}
    end
  end

  defp counted(state) do
    :ets.insert(@table, {{:meta, :waiting}, :queue.len(state.queue), nil, 0})
    state
  end

  defp idle_now(state) do
    if idle?(state) do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  # Idle for a test's purposes: nothing in flight, and nothing waiting that
  # could start. A switched-off asker holds its queue for ever.
  defp idle?(state) do
    map_size(state.running) == 0 and
      (:queue.is_empty(state.queue) or not enabled?() or circuit_open?(state))
  end

  defp circuit_open?(%{open_until: nil}), do: false
  defp circuit_open?(%{open_until: until}), do: System.monotonic_time(:millisecond) < until

  defp circuit_left do
    case :ets.lookup(@table, {:meta, :circuit}) do
      [{_, until, _, _}] -> max(until - System.monotonic_time(:millisecond), 0)
      [] -> 0
    end
  end

  defp waiting do
    case :ets.lookup(@table, {:meta, :waiting}) do
      [{_, count, _, _}] -> count
      [] -> 0
    end
  end

  defp pending?(key), do: match?({_, :pending, _, _}, lookup(key))

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [row] -> row
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp engine_down_sentence, do: :oskol@handlers@analysis.engine_down_sentence()
  defp failed_sentence, do: :oskol@handlers@analysis.failed_sentence()

  defp now_ms, do: System.system_time(:millisecond)

  def enabled?, do: config(:enabled, true)

  defp config(key, default) do
    Application.get_env(:oskol, __MODULE__, []) |> Keyword.get(key, default)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      _ -> :ok
    end
  end
end
