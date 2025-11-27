defmodule Oskol.Game.ActionCard do
  @moduledoc """
  Represents action cards that can be purchased in the shop.
  Action cards apply temporary effects for the next round only.
  """

  @type hand_type ::
          :high_card
          | :pair
          | :two_pair
          | :three_of_a_kind
          | :straight
          | :flush
          | :full_house
          | :four_of_a_kind
          | :straight_flush

  @type card_type :: :denial | :scrambler

  @type t :: %__MODULE__{
          type: card_type(),
          target_hand: hand_type() | nil
        }

  defstruct type: :denial,
            target_hand: nil

  @doc """
  Returns all available denial cards.
  """
  def all_denial_cards do
    [
      %__MODULE__{type: :denial, target_hand: :high_card},
      %__MODULE__{type: :denial, target_hand: :pair},
      %__MODULE__{type: :denial, target_hand: :two_pair},
      %__MODULE__{type: :denial, target_hand: :three_of_a_kind},
      %__MODULE__{type: :denial, target_hand: :straight},
      %__MODULE__{type: :denial, target_hand: :flush},
      %__MODULE__{type: :denial, target_hand: :full_house},
      %__MODULE__{type: :denial, target_hand: :four_of_a_kind},
      %__MODULE__{type: :denial, target_hand: :straight_flush}
    ]
  end

  @doc """
  Returns the scrambler card.
  """
  def scrambler_card do
    %__MODULE__{type: :scrambler, target_hand: nil}
  end

  @doc """
  Generates a random pool of action cards.
  Includes denial cards (tripled) and scrambler cards, randomly selects the specified count.
  """
  @spec generate_random_action_cards(pos_integer()) :: [t()]
  def generate_random_action_cards(count) do
    denial_pool =
      all_denial_cards()
      |> List.duplicate(3)
      |> List.flatten()

    # Add 3 scrambler cards to the pool
    scrambler_pool = List.duplicate(scrambler_card(), 3)

    (denial_pool ++ scrambler_pool)
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @doc """
  Returns a human-readable name for the action card.
  """
  @spec card_name(t()) :: String.t()
  def card_name(%__MODULE__{type: :denial, target_hand: hand_type}) do
    "Block #{format_hand_name(hand_type)}"
  end

  def card_name(%__MODULE__{type: :scrambler}) do
    "The Scrambler"
  end

  defp format_hand_name(:high_card), do: "High Card"
  defp format_hand_name(:pair), do: "Pair"
  defp format_hand_name(:two_pair), do: "Two Pair"
  defp format_hand_name(:three_of_a_kind), do: "3 of a Kind"
  defp format_hand_name(:straight), do: "Straight"
  defp format_hand_name(:flush), do: "Flush"
  defp format_hand_name(:full_house), do: "Full House"
  defp format_hand_name(:four_of_a_kind), do: "4 of a Kind"
  defp format_hand_name(:straight_flush), do: "Str. Flush"

  @doc """
  Returns a description of what the card does.
  """
  @spec card_description(t()) :: String.t()
  def card_description(%__MODULE__{type: :denial, target_hand: hand_type}) do
    "Opponent's #{format_hand_name(hand_type)} scores 0 next round"
  end

  def card_description(%__MODULE__{type: :scrambler}) do
    "Opponent's drawn cards have 1-in-4 chance of being face-down next round"
  end
end
