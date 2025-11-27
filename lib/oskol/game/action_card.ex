defmodule Oskol.Game.ActionCard do
  @moduledoc """
  Represents action cards that can be purchased in the shop.
  Action cards apply temporary effects for the next round only.

  Types:
  - :denial - Opponent's target_hand scores 0 next round
  - :scrambler - Opponent's drawn cards have 1-in-4 chance of being face-down
  - :plus_bomb - Pick a card; opponent's cards matching that rank OR suit score 0
  - :static - All opponent's card enhancements are disabled next round
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

  @type card_type :: :denial | :scrambler | :plus_bomb | :static

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
  Returns the PLUS BOMB action card.
  Requires card selection - opponent's cards matching rank OR suit won't score.
  """
  def plus_bomb_card do
    %__MODULE__{type: :plus_bomb, target_hand: nil}
  end

  @doc """
  Returns the STATIC action card.
  Disables all opponent's card enhancements next round.
  """
  def static_card do
    %__MODULE__{type: :static, target_hand: nil}
  end

  @doc """
  Generates a random pool of action cards.
  Includes denial cards (3x each), scrambler (3x), plus_bomb (2x), and static (2x).
  """
  @spec generate_random_action_cards(pos_integer()) :: [t()]
  def generate_random_action_cards(count) do
    pool =
      List.flatten([
        # 3 copies of each denial card
        List.duplicate(all_denial_cards(), 3) |> List.flatten(),
        # 3 copies of scrambler
        List.duplicate(scrambler_card(), 3),
        # 2 copies of plus_bomb
        List.duplicate(plus_bomb_card(), 2),
        # 2 copies of static
        List.duplicate(static_card(), 2)
      ])

    pool
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

  def card_name(%__MODULE__{type: :plus_bomb}) do
    "Plus Bomb"
  end

  def card_name(%__MODULE__{type: :static}) do
    "Static Field"
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

  def card_description(%__MODULE__{type: :plus_bomb}) do
    "Pick a card - opponent's matching rank/suit won't score"
  end

  def card_description(%__MODULE__{type: :static}) do
    "Opponent's card enhancements disabled next round"
  end

  @doc """
  Returns true if this action card requires a card selection phase.
  """
  @spec requires_selection?(t()) :: boolean()
  def requires_selection?(%__MODULE__{type: :plus_bomb}), do: true
  def requires_selection?(%__MODULE__{type: _}), do: false
end
