defmodule Oskol.ReviewsQueueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oskol.Reviews.Queue

  setup do
    previous = Application.get_env(:oskol, Queue)
    Application.put_env(:oskol, Queue, enabled: true)

    on_exit(fn ->
      Queue.await_idle()
      Queue.reset()
      Application.put_env(:oskol, Queue, previous)
    end)

    :ok
  end

  test "a failed recovery scan leaves the queue alive" do
    # No sandbox owner: querying the database fails just as an unavailable
    # connection does. The queue must catch it rather than restart and
    # forget the engine task it could have been supervising.
    log =
      capture_log(fn ->
        # Exercise the startup sweep in a test-owned queue, not a second
        # self-rescheduling timer chain in the shared application queue.
        {:ok, pid} = GenServer.start_link(Queue, [])
        :sys.get_state(pid)
        # The scan itself runs in a supervised task, off this process, so
        # wait for the scan and not merely for the cast that started it.
        await_sweep()
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)

    assert log =~ "analysis recovery sweep failed"
  end

  # The recovery scan is a task of Oskol.Reviews.TaskSupervisor; it is done
  # when the supervisor has no children left.
  defp await_sweep(left \\ 2_000) do
    cond do
      Task.Supervisor.children(Oskol.Reviews.TaskSupervisor) == [] -> :ok
      left <= 0 -> flunk("the recovery scan never finished")
      true -> Process.sleep(10) && await_sweep(left - 10)
    end
  end

  test "crashes before charging an attempt back off and stop after three, without blocking other rooms" do
    log =
      capture_log(fn ->
        # No sandbox owner: the real task dies at the first read, before
        # replay or review_one can charge an engine attempt.
        Queue.enqueue("crash-before-charge")
        Queue.await_idle()
        assert crash_count("crash-before-charge") == 1

        for count <- 1..2 do
          remaining =
            :sys.get_state(Queue).crashes["crash-before-charge"].retry_at -
              System.monotonic_time(:millisecond)

          assert remaining > count * 60_000 - 5_000
          recover("crash-before-charge")
          assert crash_count("crash-before-charge") == count

          # Advance only the retry deadline, without a minute-long test.
          expire_crash_backoff("crash-before-charge")
          recover("crash-before-charge")
          assert crash_count("crash-before-charge") == count + 1
        end

        expire_crash_backoff("crash-before-charge")

        for _ <- 1..3 do
          recover("crash-before-charge")
          assert crash_count("crash-before-charge") == 3
        end

        # A leftover engine retry timer cannot reopen a suspended room.
        generation = :sys.get_state(Queue).generation
        send(Queue, {:retry, "crash-before-charge", generation})
        Queue.await_idle()
        assert crash_count("crash-before-charge") == 3

        # Recovery of another room still runs its task.
        recover("another-room")
        assert crash_count("another-room") == 1
      end)

    assert log =~ "cannot find ownership process"
    assert length(Regex.scan(~r/REVIEW RECOVERY SUSPENDED/, log)) == 1
  end

  test "fresh requested work reopens a suspended room" do
    capture_log(fn ->
      :sys.replace_state(Queue, fn state ->
        %{state | crashes: %{"requested" => %{count: 3, retry_at: 0}}}
      end)

      Queue.enqueue("requested")
      Queue.await_idle()
      assert crash_count("requested") == 1
    end)
  end

  test "an enqueue during a failed task cannot bypass its crash backoff" do
    {:ok, state, _} = Queue.init([])
    ref = make_ref()

    state = %{
      state
      | running: {"room", ref},
        members: MapSet.new(["room"]),
        again: MapSet.new(["room"])
    }

    capture_log(fn ->
      assert {:noreply, state} = Queue.handle_info({:DOWN, ref, :process, self(), :killed}, state)
      assert state.running == nil
      assert state.again == MapSet.new()
      assert :queue.is_empty(state.queue)
      assert state.crashes["room"].count == 1
    end)
  end

  defp crash_count(game_id), do: :sys.get_state(Queue).crashes[game_id].count

  defp expire_crash_backoff(game_id) do
    :sys.replace_state(Queue, fn state ->
      put_in(state, [:crashes, game_id, :retry_at], System.monotonic_time(:millisecond) - 1)
    end)
  end

  defp recover(game_id) do
    GenServer.cast(Queue, {:recover, [game_id]})
    Queue.await_idle()
  end
end
