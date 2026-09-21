defmodule Oskol.Reviews.Queue do
  @moduledoc """
  Runs post-game reviews off the room process, one room at a time.

  A room casts `enqueue/1` when a game ends (the decision is Gleam's:
  `oskol/handlers/reviews.game_ended`), and so does the reviews endpoint for
  a failed game explicitly retried by its player. A job is one room: `oskol/handlers/reviews.run`
  reviews every game of it that is over and still owed one, one engine
  call per game. One job runs at a time, in a supervised task, so a slow
  engine (a cold machine takes seconds to wake) never holds up a room, a
  request or this process.

  Idempotent: a room already queued, running or waiting on a retry is not
  queued again, and the job itself skips games already reviewed. When a
  job reports a failure worth retrying, the room comes back after the
  backoff Gleam names; Gleam also decides that it is retried at most twice.

  The queue lives in memory. A restart forgets what was in it, which is why
  a room is marked in the database as owing an analysis before the queue is
  asked (`Oskol.Game.Persister.analysis_owed/1`), and why `sweep_owed/0`
  runs at boot and periodically to queue whatever is still marked. Reading an analysis never
  queues one: that is what took production down on 2026-09-16.

  Task crashes have a separate per-room budget, including failures before
  the engine attempt can be charged. Recovery waits one then two minutes;
  three consecutive crashes suspend automatic recovery for that room until
  a fresh enqueue or queue restart. The durable owed marker is left intact.

  `enabled` (config `:oskol, Oskol.Reviews.Queue`) is off in tests, where
  rooms finish games by the hundred and there is no engine; a test that
  wants the queue turns it on and waits with `await_idle/1`.
  """
  use GenServer
  require Logger

  @task_supervisor Oskol.Reviews.TaskSupervisor
  @sweep_interval :timer.minutes(1)
  @max_crashes 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ask for a room's owed reviews. Never blocks; a no-op when disabled."
  def enqueue(game_id) when is_binary(game_id) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:enqueue, game_id})
    :ok
  end

  @doc "Wait until nothing is queued or running (retries may still be pending). For tests."
  def await_idle(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :await_idle, timeout)
  end

  @doc "Forget everything queued, running or waiting on a retry. For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  def enabled? do
    Application.get_env(:oskol, __MODULE__, []) |> Keyword.get(:enabled, true)
  end

  @doc "One job: review what the room is owed. `{:retry, ms}` or `:ok`."
  def run(game_id) do
    # The room's last writes (the step that ended the game) go through the
    # write-behind persister; let them land before reading the log.
    Oskol.Game.Persister.flush()

    # The note as it stands before any of this is read. A game that ends
    # while the engine is working makes a newer note, and that one must
    # outlive this job: this job read the log before that game existed.
    seen = Oskol.Reviews.analysis_owed_at(game_id)

    case :oskol@handlers@reviews.run(Oskol.Gleam.CtxBuilder.build(), game_id) do
      {:some, ms} ->
        # A retry keeps the note: the work is not done until it is done.
        {:retry, ms}

      :none ->
        Oskol.Reviews.clear_analysis_owed(game_id, seen)
        :ok
    end
  end

  @doc """
  Queue every room still marked as owing an analysis.

  A game is analysed once, when it ends, and the queue that does it lives
  in memory: a restart between the game ending and the job running loses
  the job. Since a read never queues engine work, nothing else would pick
  it up. This runs at boot and periodically, so a failed task or lost
  enqueue recovers while the application stays up.

  The mark only says "look": the job skips stored grades, and a room
  already queued or running is not queued again. A request whose answer
  was lost in a crash may be retried within the attempt budget.
  """
  def sweep_owed do
    if enabled?() do
      owed = Oskol.Reviews.rooms_owed_analysis()
      GenServer.cast(__MODULE__, {:recover, owed})
      length(owed)
    else
      0
    end
  end

  # ---------- Server ----------

  @impl true
  def init(_opts) do
    # After the supervisor is up, not during it: the sweep reads the
    # database, and nothing else should wait on that to start.
    {:ok, fresh(0), {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    recover_owed()
    {:noreply, state}
  end

  # Recovery must survive an unavailable database without restarting the
  # queue (which could orphan its running engine task). Always schedule the
  # next scan; no read endpoint is responsible for dispatching this work.
  defp recover_owed do
    Process.send_after(self(), :sweep, @sweep_interval)

    try do
      sweep_owed()
    rescue
      e -> Logger.error("analysis recovery sweep failed: #{Exception.message(e)}")
    catch
      kind, reason -> Logger.error("analysis recovery sweep failed: #{inspect({kind, reason})}")
    end
  end

  # `generation` tells a retry timer set before a reset from one set after.
  defp fresh(generation) do
    %{
      queue: :queue.new(),
      members: MapSet.new(),
      running: nil,
      # Rooms enqueued again while their job ran: they run once more.
      again: MapSet.new(),
      crashes: %{},
      waiters: [],
      generation: generation
    }
  end

  @impl true
  def handle_cast({:recover, game_ids}, state) do
    # A sweep must not mark a running room as needing another run: the
    # durable marker stays set throughout the engine request. Only a new
    # game ending (the regular enqueue path) requests that second pass.
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(game_ids, state, fn game_id, acc ->
        if MapSet.member?(acc.members, game_id) or crash_blocked?(acc, game_id, now) do
          acc
        else
          %{acc | queue: :queue.in(game_id, acc.queue), members: MapSet.put(acc.members, game_id)}
        end
      end)

    {:noreply, next(state)}
  end

  def handle_cast({:enqueue, game_id}, state) do
    # Only fresh requested work (a game ending or an explicit player retry)
    # reopens a crashed room. The periodic sweep never resets its budget.
    state = %{state | crashes: Map.delete(state.crashes, game_id)}

    cond do
      # The job for this room is running and may have read the log before
      # this game ended (the next game of a match finishing while the last
      # one is reviewed): run the room once more when it is done.
      match?({^game_id, _}, state.running) ->
        {:noreply, %{state | again: MapSet.put(state.again, game_id)}}

      # Queued, or waiting on a retry that will review everything owed.
      MapSet.member?(state.members, game_id) ->
        {:noreply, state}

      true ->
        state = %{
          state
          | queue: :queue.in(game_id, state.queue),
            members: MapSet.put(state.members, game_id)
        }

        {:noreply, next(state)}
    end
  end

  @impl true
  def handle_call(:reset, _from, state), do: {:reply, :ok, fresh(state.generation + 1)}

  def handle_call(:await_idle, from, state) do
    if idle?(state),
      do: {:reply, :ok, state},
      else: {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_info(:sweep, state) do
    recover_owed()
    {:noreply, state}
  end

  def handle_info({ref, result}, %{running: {game_id, ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | crashes: Map.delete(state.crashes, game_id)}

    state =
      case result do
        {:retry, ms} ->
          Process.send_after(self(), {:retry, game_id, state.generation}, ms)
          state

        _ ->
          %{state | members: MapSet.delete(state.members, game_id)}
      end

    {:noreply, next(finished(state, game_id))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: {game_id, ref}} = state) do
    count = Map.get(state.crashes, game_id, %{count: 0}).count + 1
    retry_at = System.monotonic_time(:millisecond) + @sweep_interval * count

    if count >= @max_crashes do
      Logger.error(
        "REVIEW RECOVERY SUSPENDED (#{game_id}) after #{count} task crashes: #{inspect(reason)}"
      )
    else
      Logger.error("REVIEW FAILED (#{game_id}), crash #{count}: #{inspect(reason)}")
    end

    # Do not call finished/2: an enqueue received during this failed task
    # must not bypass the crash backoff via `again`. Its durable marker is
    # still owed and the next eligible sweep will include the newer game.
    state = %{
      state
      | running: nil,
        members: MapSet.delete(state.members, game_id),
        again: MapSet.delete(state.again, game_id),
        crashes: Map.put(state.crashes, game_id, %{count: count, retry_at: retry_at})
    }

    {:noreply, next(state)}
  end

  # A retry comes due: still a member, so straight back into the line.
  def handle_info({:retry, game_id, generation}, %{generation: generation} = state) do
    if MapSet.member?(state.members, game_id) and
         not match?({^game_id, _}, state.running) and
         not :queue.member(game_id, state.queue) and
         not crash_blocked?(state, game_id, System.monotonic_time(:millisecond)) do
      {:noreply, next(%{state | queue: :queue.in(game_id, state.queue)})}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp crash_blocked?(state, game_id, now) do
    case Map.get(state.crashes, game_id) do
      nil -> false
      %{count: count, retry_at: retry_at} -> count >= @max_crashes or now < retry_at
    end
  end

  # A job is over; a room enqueued again meanwhile goes straight back in
  # line (a duplicate run is harmless: what is done is skipped).
  defp finished(state, game_id) do
    state = %{state | running: nil}

    if MapSet.member?(state.again, game_id) do
      %{
        state
        | again: MapSet.delete(state.again, game_id),
          queue: :queue.in(game_id, state.queue),
          members: MapSet.put(state.members, game_id)
      }
    else
      state
    end
  end

  defp next(%{running: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, game_id}, queue} ->
        task = Task.Supervisor.async_nolink(@task_supervisor, fn -> run(game_id) end)
        %{state | queue: queue, running: {game_id, task.ref}}

      {:empty, _} ->
        Enum.each(state.waiters, &GenServer.reply(&1, :ok))
        %{state | waiters: []}
    end
  end

  defp next(state), do: state

  defp idle?(state), do: state.running == nil and :queue.is_empty(state.queue)
end
