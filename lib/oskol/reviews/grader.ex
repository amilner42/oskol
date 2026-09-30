defmodule Oskol.Reviews.Grader do
  @moduledoc """
  Grades a backgammon turn the moment it is committed, so the report is ready
  when the game ends.

  A room casts one turn here after it has told both players about it, and
  carries on. What a turn is and what the engine is asked about it is Gleam's
  (`backgammon/analysis.committed_json`, reached through
  `Oskol.GameKit.committed/1`); this posts that body and writes the answer to
  `turn_grades`, which the end-of-game review job reads as a cache
  (`oskol/handlers/reviews.answer`).

  **Nothing here reaches a player.** It answers nobody, messages no room, and
  publishes nothing: the one thing a grade ever becomes is a row in a table
  whose only reader grades finished games. The capability to read that table
  is not even in the context a request handler is given
  (`oskol/caps/analysis.no_grades`), so a handler that tried would be a loud
  500 rather than a quiet leak. A game on the board is absent from
  `/reviews`, not pending.

  It asks and never waits. A turn it drops -- because the line is full,
  because the engine just failed, because the machine is asleep -- is a cache
  miss and nothing more: the review job asks the engine for it at the end,
  exactly as it did before any of this existed. So the bounds below are set
  to protect the engine and this process, not to get every turn graded:

    * `@in_flight` requests at once. The engine interleaves the analyses of
      one turn across its cores, so more in flight buys little and queues
      behind itself.
    * `@pending` waiting, oldest dropped first: a turn that has waited while
      a hundred others were graded is a turn whose game has probably ended.
    * `@circuit_ms` of silence after a failure. A desktop asleep behind a
      tailnet refuses a connection instantly, and hammering it every turn of
      every room would be the one way this could cost anything.

  Drops are logged once with a count, never per turn.

  `enabled` (config `:oskol, Oskol.Reviews.Grader`) is off in tests, where
  rooms finish games by the hundred and there is no engine; a test that wants
  it turns it on and waits with `await_idle/1`.
  """
  use GenServer
  require Logger

  alias Oskol.Reviews

  # Its own task supervisor, not the review queue's: the two are unrelated
  # work and a caller that waits on one supervisor's children being done
  # (the recovery-sweep test does) must not be waiting on the other's.
  @task_supervisor Oskol.Reviews.GraderSupervisor
  @in_flight 4
  @pending 100
  @circuit_ms 60_000
  # A room nobody finished leaves its grades behind; nothing else does.
  @keep_days 7
  @sweep_interval :timer.hours(1)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Grade this committed turn. Never blocks, never answers, and is a no-op when
  the Grader is off.

  `payload` is what `Oskol.GameKit.committed/1` handed back: the JSON the game
  itself built for the turn.
  """
  def grade(game_id, payload) when is_binary(game_id) and is_binary(payload) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:grade, game_id, payload})
    :ok
  end

  @doc "Wait until nothing is queued or in flight. For tests."
  def await_idle(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :await_idle, timeout)
  end

  @doc "Forget everything queued, in flight and any open circuit. For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  def enabled? do
    Application.get_env(:oskol, __MODULE__, []) |> Keyword.get(:enabled, true)
  end

  # ---------- Server ----------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, fresh()}
  end

  defp fresh do
    %{
      queue: :queue.new(),
      waiting: 0,
      running: MapSet.new(),
      # Nothing rather than a moment in the past: monotonic time starts
      # far below zero on some machines, and a zero here read as a circuit
      # that had been open since boot.
      open_until: nil,
      dropped: 0,
      waiters: []
    }
  end

  @impl true
  def handle_cast({:grade, game_id, payload}, state) do
    cond do
      # The engine just failed. Every turn of every live room would arrive
      # here and fail the same way; none of them is worth a connection.
      circuit_open?(state) ->
        {:noreply, dropped(state)}

      state.waiting >= @pending ->
        # The oldest waiting turn has waited through a hundred others: its
        # game is likely over and the job has already asked about it.
        {{:value, _}, queue} = :queue.out(state.queue)

        {:noreply, dropped(%{state | queue: :queue.in({game_id, payload}, queue)})}

      true ->
        state = %{
          state
          | queue: :queue.in({game_id, payload}, state.queue),
            waiting: state.waiting + 1
        }

        {:noreply, start_next(state)}
    end
  end

  @impl true
  def handle_call(:await_idle, from, state) do
    if idle?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, fresh()}

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_interval)

    Task.Supervisor.start_child(@task_supervisor, fn ->
      case Reviews.sweep_turn_grades(@keep_days) do
        0 -> :ok
        count -> Logger.info("dropped #{count} turn grades older than #{@keep_days} days")
      end
    end)

    {:noreply, state}
  end

  # A task saying the engine did not answer. Before the task-result clause
  # below, which any two-tuple would otherwise match.
  def handle_info({:engine_failed, reason}, state) do
    Logger.warning("turn grading paused for #{div(@circuit_ms, 1000)}s: #{reason}")
    {:noreply, circuit_open(state)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if MapSet.member?(state.running, ref) do
      Logger.warning("turn grading crashed: #{inspect(reason)}")
      {:noreply, finished(circuit_open(state), ref)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp circuit_open(state) do
    %{state | open_until: System.monotonic_time(:millisecond) + @circuit_ms}
  end

  defp circuit_open?(%{open_until: nil}), do: false

  defp circuit_open?(%{open_until: until}),
    do: System.monotonic_time(:millisecond) < until

  defp dropped(state) do
    count = state.dropped + 1
    # One line per ten, not one per turn: a sleeping engine drops every turn
    # of every room and the count is the only interesting part.
    if rem(count, 10) == 1 do
      Logger.info("turn grading dropped #{count} turns (engine unavailable or busy)")
    end

    %{state | dropped: count}
  end

  defp finished(state, ref) do
    state = %{state | running: MapSet.delete(state.running, ref)}
    start_next(state)
  end

  defp start_next(state) do
    if MapSet.size(state.running) < @in_flight do
      case :queue.out(state.queue) do
        {{:value, {game_id, payload}}, queue} ->
          grader = self()

          task =
            Task.Supervisor.async_nolink(@task_supervisor, fn ->
              store(grader, game_id, payload)
            end)

          start_next(%{
            state
            | queue: queue,
              waiting: state.waiting - 1,
              running: MapSet.put(state.running, task.ref)
          })

        {:empty, _} ->
          reply_to_waiters(state)
      end
    else
      state
    end
  end

  defp reply_to_waiters(state) do
    if idle?(state) do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  defp idle?(state), do: state.waiting == 0 and MapSet.size(state.running) == 0

  # One turn, in its own task: ask the engine and write the answer down.
  # Nothing is sent anywhere and nothing is returned; the Grader is told only
  # that the engine is not answering, so it can stop asking for a while.
  defp store(grader, game_id, payload) do
    with {:ok, %{"game_number" => number, "body" => body}} <- Jason.decode(payload),
         # A duplicate cast has nothing to add: the answer to this exact
         # question is already stored.
         false <- Reviews.turn_graded?(game_id, number, body),
         {:ok, response} <- Reviews.request(body) do
      Reviews.save_turn_grade(game_id, number, body, Jason.decode!(response))
    else
      {:error, reason} when is_binary(reason) ->
        send(grader, {:engine_failed, reason})

      _ ->
        :ok
    end
  end
end
