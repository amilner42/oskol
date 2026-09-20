defmodule Oskol.Auth.LimiterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Oskol.Auth.Limiter

  setup do
    Limiter.reset()
    :ok
  end

  test "concurrent first hits are counted atomically" do
    counts =
      1..32
      |> Task.async_stream(fn _ -> Limiter.count("same-key", 3_600) end,
        max_concurrency: 32,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, count} -> count end)

    assert Enum.sort(counts) == Enum.to_list(1..32)
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

    assert Limiter.count("global", 3_600) == 2
  end

  test "an allowed reservation preserves a live bucket's fixed window start" do
    started = System.system_time(:second) - 600
    :ets.insert(Limiter, {"global", started, 1})

    assert Limiter.allow_mail([{:limit_bucket, "global", 3, 3_600}])
    assert [{"global", ^started, 2}] = :ets.lookup(Limiter, "global")
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

  test "a fixed-window warning marker survives an epoch boundary" do
    started = System.system_time(:second) - 600
    :ets.insert(Limiter, {"start:source:opaque-source", started, 1})
    :ets.insert(Limiter, {{:limit_log, "source", started, 3_600}, started, 1})

    log =
      capture_log(fn ->
        refute Limiter.allow_mail([{:limit_bucket, "start:source:opaque-source", 1, 3_600}])
      end)

    refute log =~ "auth mail limited: source"
  end
end
