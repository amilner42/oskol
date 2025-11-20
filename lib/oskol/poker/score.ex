defmodule Oskol.Poker.Score do
  @moduledoc """
  Calculates scores for poker hands.
  """

  alias Oskol.Poker.{Card, Hand}
  alias Oskol.Poker.SkillTree

  @type score_result :: %{
          hand_type: Hand.hand_type(),
          total_chips: integer(),
          total_multiplier: integer(),
          total_score: integer()
        }

  @base_hand_scores %{
    high_card: %{chips: 5, multiplier: 1},
    pair: %{chips: 10, multiplier: 2},
    two_pair: %{chips: 20, multiplier: 2},
    three_of_a_kind: %{chips: 30, multiplier: 3},
    straight: %{chips: 30, multiplier: 4},
    flush: %{chips: 35, multiplier: 4},
    full_house: %{chips: 40, multiplier: 4},
    four_of_a_kind: %{chips: 60, multiplier: 7},
    straight_flush: %{chips: 100, multiplier: 8}
  }

  @upgrade_bonuses %{
    high_card: %{chips: 10, multiplier: 1},
    pair: %{chips: 15, multiplier: 1},
    two_pair: %{chips: 20, multiplier: 1},
    three_of_a_kind: %{chips: 20, multiplier: 2},
    straight: %{chips: 30, multiplier: 3},
    flush: %{chips: 15, multiplier: 2},
    full_house: %{chips: 25, multiplier: 2},
    four_of_a_kind: %{chips: 30, multiplier: 3},
    straight_flush: %{chips: 40, multiplier: 4}
  }

  @doc """
  Returns the base hand scores map.
  """
  def base_hand_scores, do: @base_hand_scores

  @doc """
  Returns the upgrade bonuses map.
  """
  def upgrade_bonuses, do: @upgrade_bonuses

  @doc """
  Calculates the base chips and multiplier for a given hand type at a specific level.
  Does not include card values - this is for preview purposes in the shop.

  Returns `%{base_chips: integer(), multiplier: integer()}`
  """
  @spec stats_at_level(Hand.hand_type(), pos_integer()) :: %{
          base_chips: integer(),
          multiplier: integer()
        }
  def stats_at_level(hand_type, level) do
    base = @base_hand_scores[hand_type]
    upgrade = @upgrade_bonuses[hand_type]

    bonus_multiplier = max(0, level - 1)

    %{
      base_chips: base.chips + bonus_multiplier * upgrade.chips,
      multiplier: base.multiplier + bonus_multiplier * upgrade.multiplier
    }
  end

  @doc """
  Calculates the score for a hand evaluation with skill tree levels and debuffs applied.

  Level 1 = base scores only
  Level 2+ = base + (level - 1) × upgrade bonus

  If hand_type is in active_debuffs, score is 0 (denial).

  Only scoring_cards contribute to the card value sum.
  """
  @spec calculate(Hand.evaluation(), SkillTree.t(), list(Hand.hand_type())) :: score_result()
  def calculate(
        %{hand_type: hand_type, scoring_cards: scoring_cards},
        %SkillTree{} = skill_tree,
        active_debuffs \\ []
      ) do
    # Check if this hand type is denied (scores 0)
    if hand_type in active_debuffs do
      %{
        hand_type: hand_type,
        total_chips: 0,
        total_multiplier: 0,
        total_score: 0
      }
    else
      # Get level for this hand type
      level = Map.get(skill_tree, hand_type)

      # Get base scores
      base = @base_hand_scores[hand_type]

      # Calculate level bonuses (level 1 = no bonus, level 2 = 1x bonus, etc.)
      bonus_multiplier = max(0, level - 1)
      upgrade = @upgrade_bonuses[hand_type]

      # Apply bonuses
      total_base_chips = base.chips + bonus_multiplier * upgrade.chips
      total_multiplier = base.multiplier + bonus_multiplier * upgrade.multiplier

      # Calculate card values and final score (only scoring cards count)
      card_value_sum = Enum.sum(Enum.map(scoring_cards, &Card.chip_value/1))
      total_chips = total_base_chips + card_value_sum
      total_score = total_chips * total_multiplier

      %{
        hand_type: hand_type,
        total_chips: total_chips,
        total_multiplier: total_multiplier,
        total_score: total_score
      }
    end
  end
end
