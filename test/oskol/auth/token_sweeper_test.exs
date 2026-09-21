defmodule Oskol.Auth.TokenSweeperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Oskol.Auth.TokenSweeper

  test "runs a bounded pass promptly after startup and then keeps its state" do
    parent = self()

    assert {:ok, state, {:continue, :sweep}} =
             TokenSweeper.init(sweep: fn limit -> send(parent, {:swept, limit}) end)

    assert {:noreply, ^state} = TokenSweeper.handle_continue(:sweep, state)
    assert_receive {:swept, 1_000}
  end

  test "a failed pass is logged and does not terminate the worker" do
    assert {:ok, state, {:continue, :sweep}} =
             TokenSweeper.init(sweep: fn _ -> raise "database unavailable" end)

    log =
      capture_log(fn ->
        assert {:noreply, ^state} = TokenSweeper.handle_continue(:sweep, state)
      end)

    assert log =~ "auth token sweep failed"
  end
end
