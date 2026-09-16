defmodule Oskol.Reviews.Queue do
  @moduledoc """
  Runs post-game reviews off the room process, one room at a time.

  A room casts `enqueue/1` when a game ends (the decision is Gleam's:
  `oskol/handlers/reviews.game_ended`), and so does the reviews endpoint for
  a game that has none yet. A job is one room: `oskol/handlers/reviews.run`
  reviews every game of it that is over and still owed one, one engine
  call per game. One job runs at a time, in a supervised task, so a slow
  engine (a cold machine takes seconds to wake) never holds up a room, a
  request or this process.

  Idempotent: a room already queued, running or waiting on a retry is not
  queued again, and the job itself skips games already reviewed. When a
  job reports a failure worth retrying, the room comes back after the
  backoff Gleam names; Gleam also decides that it is retried at most twice.

  The queue lives in memory. A restart forgets it, which is fine: every
  game still owed a review is queued again by the first request for it.

  `enabled` (config `:oskol, Oskol.Reviews.Queue`) is off in tests, where
  rooms finish games by the hundred and there is no engine; a test that
  wants the queue turns it on and waits with `await_idle/1`.
  """
  use GenServer
  require Logger

  @task_supervisor Oskol.Reviews.TaskSupervisor

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

    case :oskol@handlers@reviews.run(Oskol.Gleam.CtxBuilder.build(), game_id) do
      {:some, ms} -> {:retry, ms}
      :none -> :ok
    end
  end

  # ---------- Server ----------

  @impl true
  def init(_opts) do
    {:ok, fresh(0)}
  end

  # `generation` tells a retry timer set before a reset from one set after.
  defp fresh(generation) do
    %{
      queue: :queue.new(),
      members: MapSet.new(),
      running: nil,
      # Rooms enqueued again while their job ran: they run once more.
      again: MapSet.new(),
      waiters: [],
      generation: generation
    }
  end

  @impl true
  def handle_cast({:enqueue, game_id}, state) do
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
  def handle_info({ref, result}, %{running: {game_id, ref}} = state) do
    Process.demonitor(ref, [:flush])

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
    Logger.error("REVIEW FAILED (#{game_id}): #{inspect(reason)}")
    state = %{state | members: MapSet.delete(state.members, game_id)}
    {:noreply, next(finished(state, game_id))}
  end

  # A retry comes due: still a member, so straight back into the line.
  def handle_info({:retry, game_id, generation}, %{generation: generation} = state) do
    {:noreply, next(%{state | queue: :queue.in(game_id, state.queue)})}
  end

  def handle_info(_other, state), do: {:noreply, state}

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
