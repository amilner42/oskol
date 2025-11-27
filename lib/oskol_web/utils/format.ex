defmodule OskolWeb.Utils.Format do
  @moduledoc """
  Shared formatting utilities for the web layer.
  """

  @doc """
  Returns a human-readable name for a poker hand type.

  ## Examples

      iex> hand_name(:high_card)
      "High Card"

      iex> hand_name(:three_of_a_kind)
      "3 of a Kind"
  """
  @spec hand_name(atom()) :: String.t()
  def hand_name(:high_card), do: "High Card"
  def hand_name(:pair), do: "Pair"
  def hand_name(:two_pair), do: "Two Pair"
  def hand_name(:three_of_a_kind), do: "3 of a Kind"
  def hand_name(:straight), do: "Straight"
  def hand_name(:flush), do: "Flush"
  def hand_name(:full_house), do: "Full House"
  def hand_name(:four_of_a_kind), do: "4 of a Kind"
  def hand_name(:straight_flush), do: "Straight Flush"
end
