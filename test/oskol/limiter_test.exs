defmodule Oskol.LimiterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Oskol.Limiter

  setup do
    Limiter.reset()
    :ok
  end

  test "concurrent reservations cannot exceed a fresh bucket's limit" do
    allowed =
      1..32
      |> Task.async_stream(
        fn _ -> Limiter.allow_mail([{:limit_bucket, "same-key", 32, 3_600}]) end,
        max_concurrency: 32,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, allowed?} -> allowed? end)

    assert Enum.all?(allowed)
    refute Limiter.allow_mail([{:limit_bucket, "same-key", 32, 3_600}])
    assert [{"same-key", _started, 32, 3_600}] = :ets.lookup(Limiter, "same-key")
  end

  test "a rejected multi-bucket reservation consumes none of its buckets" do
    assert Limiter.allow_mail([
             {:limit_bucket, "guest", 1, 3_600},
             {:limit_bucket, "global", 1, 3_600}
           ])

    refute Limiter.allow_mail([
             {:limit_bucket, "guest", 1, 3_600},
             {:limit_bucket, "global", 1, 3_600}
           ])

    assert [{"global", _started, 1, 3_600}] = :ets.lookup(Limiter, "global")
  end

  test "an allowed reservation preserves a live bucket's fixed window start" do
    started = System.system_time(:second) - 600
    :ets.insert(Limiter, {"global", started, 1, 3_600})

    assert Limiter.allow_mail([{:limit_bucket, "global", 3, 3_600}])
    assert [{"global", ^started, 2, 3_600}] = :ets.lookup(Limiter, "global")
  end

  test "refusals log an anonymous bucket name once per window" do
    assert Limiter.allow_mail([{:limit_bucket, "start:source:opaque-source", 1, 3_600}])

    log =
      capture_log(fn ->
        Enum.each(1..3, fn _ ->
          refute Limiter.allow_mail([{:limit_bucket, "start:source:opaque-source", 1, 3_600}])
        end)
      end)

    assert log =~ "auth mail limited: source"
    refute log =~ "opaque-source"
    assert length(String.split(log, "auth mail limited: source")) == 2
  end

  test "a refusal names the full bucket that frees up last, and how long until it does" do
    started = System.system_time(:second) - 600
    :ets.insert(Limiter, {"analysis:user:u1:hour", started, 30, 3_600})
    :ets.insert(Limiter, {"analysis:user:u1:day", started, 150, 86_400})

    assert {:error, {:refused, "analysis:user:u1:day", wait}} =
             Limiter.allow([
               {:limit_bucket, "analysis:user:u1:hour", 30, 3_600},
               {:limit_bucket, "analysis:user:u1:day", 150, 86_400},
               {:limit_bucket, "analysis:global:day", 600, 86_400}
             ])

    assert wait in (86_400 - 601)..(86_400 - 599)
    assert :ets.lookup(Limiter, "analysis:global:day") == []
    assert {:ok, nil} = Limiter.allow([{:limit_bucket, "analysis:global:day", 600, 86_400}])
  end

  test "a release hands one use back, and never below nothing" do
    bucket = {:limit_bucket, "analysis:global:day", 600, 86_400}
    assert {:ok, nil} = Limiter.allow([bucket])
    assert {:ok, nil} = Limiter.allow([bucket])
    assert :ok = Limiter.release([bucket])
    assert [{_, _, 1, 86_400}] = :ets.lookup(Limiter, "analysis:global:day")
    assert :ok = Limiter.release([bucket, {:limit_bucket, "analysis:never", 1, 60}])
    assert :ok = Limiter.release([bucket])
    assert [{_, _, 0, 86_400}] = :ets.lookup(Limiter, "analysis:global:day")
    assert :ets.lookup(Limiter, "analysis:never") == []
  end

  test "an unavailable limiter fails closed for asks and open for mail" do
    pid = Process.whereis(Limiter)
    assert Process.unregister(Limiter)

    on_exit(fn ->
      if Process.whereis(Limiter) == nil, do: Process.register(pid, Limiter)
    end)

    assert {:error, {:refused, "analysis:limiter", 30}} =
             Limiter.allow([{:limit_bucket, "analysis:global:day", 600, 86_400}])

    assert Limiter.allow_mail([{:limit_bucket, "start:global", 1, 3_600}])
    assert :ok = Limiter.release([{:limit_bucket, "analysis:global:day", 600, 86_400}])
    assert Process.register(pid, Limiter)
  end

  test "an analysis refusal logs under its own name, never the id" do
    assert {:ok, nil} = Limiter.allow([{:limit_bucket, "analysis:user:secret-id:hour", 1, 3_600}])

    log =
      capture_log(fn ->
        assert {:error, _} =
                 Limiter.allow([{:limit_bucket, "analysis:user:secret-id:hour", 1, 3_600}])
      end)

    assert log =~ "analysis limited: user"
    refute log =~ "auth mail"
    refute log =~ "secret-id"
  end

  test "a fixed-window warning marker survives an epoch boundary" do
    started = System.system_time(:second) - 600
    :ets.insert(Limiter, {"start:source:opaque-source", started, 1, 3_600})
    :ets.insert(Limiter, {{:limit_log, "source", started, 3_600}, started, 1, 3_600})

    log =
      capture_log(fn ->
        refute Limiter.allow_mail([{:limit_bucket, "start:source:opaque-source", 1, 3_600}])
      end)

    refute log =~ "auth mail limited: source"
  end

  test "an unavailable limiter fails open instead of exiting the request" do
    pid = Process.whereis(Limiter)
    assert is_pid(pid)
    assert Process.unregister(Limiter)

    on_exit(fn ->
      if Process.whereis(Limiter) == nil, do: Process.register(pid, Limiter)
    end)

    assert Limiter.allow_mail([{:limit_bucket, "global", 1, 3_600}])
    assert Process.register(pid, Limiter)
  end

  test "housekeeping preserves a configured window longer than one day" do
    started = System.system_time(:second) - div(:timer.hours(25), 1_000)
    :ets.insert(Limiter, {"long-window", started, 1, div(:timer.hours(48), 1_000)})

    assert {:noreply, %{}} = Limiter.handle_info(:sweep, %{})
    assert [{"long-window", ^started, 1, _window_s}] = :ets.lookup(Limiter, "long-window")
  end
end
