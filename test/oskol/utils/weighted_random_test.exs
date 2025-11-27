defmodule Oskol.Utils.WeightedRandomTest do
  use ExUnit.Case, async: true

  alias Oskol.Utils.WeightedRandom

  doctest WeightedRandom

  describe "sample/1" do
    test "samples from a single-item map always returns that item" do
      result = WeightedRandom.sample(%{only_item: 1})
      assert result == :only_item
    end

    test "samples from a map with equal weights gives roughly equal distribution" do
      weights = %{a: 1, b: 1, c: 1}
      samples = for _ <- 1..3000, do: WeightedRandom.sample(weights)

      counts = Enum.frequencies(samples)

      # Each should appear roughly 1000 times (± 200 for randomness)
      assert counts[:a] > 800 and counts[:a] < 1200
      assert counts[:b] > 800 and counts[:b] < 1200
      assert counts[:c] > 800 and counts[:c] < 1200
    end

    test "samples respect weight ratios" do
      # Item 'a' should appear 3x more often than 'b'
      weights = %{a: 3, b: 1}
      samples = for _ <- 1..4000, do: WeightedRandom.sample(weights)

      counts = Enum.frequencies(samples)

      # 'a' should be ~3000, 'b' should be ~1000
      ratio = counts[:a] / counts[:b]
      # Ratio should be close to 3.0 (± 0.5)
      assert ratio > 2.5 and ratio < 3.5
    end

    test "samples work with various weight distributions" do
      weights = %{
        rare: 1,
        uncommon: 5,
        common: 10
      }

      samples = for _ <- 1..16000, do: WeightedRandom.sample(weights)

      counts = Enum.frequencies(samples)

      # Total weight = 16, so in 16000 samples:
      # rare: ~1000, uncommon: ~5000, common: ~10000
      assert counts[:rare] > 500 and counts[:rare] < 1500
      assert counts[:uncommon] > 4000 and counts[:uncommon] < 6000
      assert counts[:common] > 9000 and counts[:common] < 11000
    end

    test "works with non-atom keys" do
      weights = %{"string_key" => 1, 123 => 1}
      result = WeightedRandom.sample(weights)
      assert result in ["string_key", 123]
    end

    test "raises ArgumentError when given an empty map" do
      assert_raise ArgumentError, "Cannot sample from an empty map", fn ->
        WeightedRandom.sample(%{})
      end
    end

    test "raises ArgumentError when weight is zero" do
      assert_raise ArgumentError, ~r/All weights must be positive integers/, fn ->
        WeightedRandom.sample(%{a: 0})
      end
    end

    test "raises ArgumentError when weight is negative" do
      assert_raise ArgumentError, ~r/All weights must be positive integers/, fn ->
        WeightedRandom.sample(%{a: -1})
      end
    end

    test "raises ArgumentError when weight is not an integer" do
      assert_raise ArgumentError, ~r/All weights must be positive integers/, fn ->
        WeightedRandom.sample(%{a: 1.5})
      end
    end
  end

  describe "sample_n/2" do
    test "returns correct number of samples" do
      weights = %{a: 1, b: 1}

      assert length(WeightedRandom.sample_n(weights, 0)) == 0
      assert length(WeightedRandom.sample_n(weights, 1)) == 1
      assert length(WeightedRandom.sample_n(weights, 5)) == 5
      assert length(WeightedRandom.sample_n(weights, 100)) == 100
    end

    test "all samples are from the available items" do
      weights = %{x: 2, y: 3}
      samples = WeightedRandom.sample_n(weights, 50)

      assert Enum.all?(samples, fn item -> item in [:x, :y] end)
    end

    test "samples are independent (duplicates possible)" do
      weights = %{single_item: 1}
      samples = WeightedRandom.sample_n(weights, 10)

      # All 10 samples should be the same item (because there's only one)
      assert samples == List.duplicate(:single_item, 10)
    end

    test "respects weight distribution over multiple samples" do
      weights = %{high: 9, low: 1}
      samples = WeightedRandom.sample_n(weights, 1000)

      counts = Enum.frequencies(samples)

      # 'high' should appear ~900 times, 'low' ~100 times
      assert counts[:high] > 800 and counts[:high] < 950
      assert counts[:low] > 50 and counts[:low] < 200
    end
  end
end
