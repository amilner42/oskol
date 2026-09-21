defmodule Oskol.ReviewsQueueTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oskol.Reviews.Queue

  test "a failed recovery scan leaves the queue alive" do
    previous = Application.get_env(:oskol, Queue)
    Application.put_env(:oskol, Queue, enabled: true)
    on_exit(fn -> Application.put_env(:oskol, Queue, previous) end)
    pid = Process.whereis(Queue)

    # No sandbox owner: querying the database fails just as an unavailable
    # connection does. The queue must catch it rather than restart and
    # forget the engine task it could have been supervising.
    log =
      capture_log(fn ->
        send(pid, :sweep)
        :sys.get_state(pid)
      end)

    assert log =~ "analysis recovery sweep failed"
    assert Process.whereis(Queue) == pid
  end
end
