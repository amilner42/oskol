defmodule Oskol.Auth.LimiterTest do
  use ExUnit.Case, async: false

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
end
