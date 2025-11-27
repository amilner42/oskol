defmodule Oskol.Utils.WeightedRandom do
  @moduledoc """
  Utilities for weighted random sampling.

  This module provides functions for sampling from weighted distributions,
  commonly used in game mechanics like loot tables, shop generation, etc.
  """

  @doc """
  Samples a single item from a weighted map.

  Each item in the map has an associated weight (positive integer).
  Items with higher weights are more likely to be selected.

  ## Examples

      iex> # Fixed seed for deterministic example
      iex> :rand.seed(:exsss, {1, 2, 3})
      iex> Oskol.Utils.WeightedRandom.sample(%{a: 1, b: 2, c: 1})
      :b

      iex> # Equal weights = equal probability (over many samples)
      iex> weights = %{heads: 1, tails: 1}
      iex> results = for _ <- 1..1000, do: Oskol.Utils.WeightedRandom.sample(weights)
      iex> heads_count = Enum.count(results, & &1 == :heads)
      iex> # Should be roughly 500 ± 100
      iex> heads_count > 400 and heads_count < 600
      true

  ## Parameters

    - `weighted_map` - A map where keys are items and values are positive integer weights

  ## Returns

  The selected item (a key from the input map)

  ## Raises

  - `ArgumentError` if the map is empty
  - `ArgumentError` if any weight is not a positive integer
  """
  @spec sample(%{any() => pos_integer()}) :: any()
  def sample(weighted_map) when map_size(weighted_map) > 0 do
    # Validate weights
    Enum.each(weighted_map, fn {_item, weight} ->
      unless is_integer(weight) and weight > 0 do
        raise ArgumentError, "All weights must be positive integers, got: #{inspect(weight)}"
      end
    end)

    items_with_weights = Enum.to_list(weighted_map)

    # Calculate total weight
    total_weight = Enum.reduce(items_with_weights, 0, fn {_item, weight}, acc -> acc + weight end)

    # Generate random number in range [1, total_weight]
    random_value = :rand.uniform(total_weight)

    # Find the item that corresponds to this random value
    {selected_item, _weight} =
      Enum.reduce_while(items_with_weights, {nil, 0}, fn {item, weight},
                                                         {_current_item, cumulative} ->
        new_cumulative = cumulative + weight

        if random_value <= new_cumulative do
          {:halt, {item, weight}}
        else
          {:cont, {item, new_cumulative}}
        end
      end)

    selected_item
  end

  def sample(weighted_map) when map_size(weighted_map) == 0 do
    raise ArgumentError, "Cannot sample from an empty map"
  end

  @doc """
  Samples multiple items from a weighted map with replacement.

  Each sample is independent - selecting an item doesn't change the
  probability of selecting it again.

  ## Examples

      iex> weights = %{a: 1, b: 1}
      iex> samples = Oskol.Utils.WeightedRandom.sample_n(weights, 5)
      iex> length(samples)
      5
      iex> Enum.all?(samples, fn item -> item in [:a, :b] end)
      true

  ## Parameters

    - `weighted_map` - A map where keys are items and values are positive integer weights
    - `n` - Number of samples to draw

  ## Returns

  A list of `n` sampled items
  """
  @spec sample_n(%{any() => pos_integer()}, non_neg_integer()) :: [any()]
  def sample_n(_weighted_map, 0), do: []

  def sample_n(weighted_map, n) when is_integer(n) and n > 0 do
    for _ <- 1..n, do: sample(weighted_map)
  end
end
