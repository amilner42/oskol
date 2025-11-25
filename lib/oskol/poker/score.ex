defmodule Oskol.Poker.Score do
  @moduledoc """
  Calculates scores for poker hands.
  """

  alias Oskol.Poker.{Card, Hand}
  alias Oskol.Poker.SkillTree

  @type card_breakdown :: %{
          card: Card.t(),
          chip_value: integer(),
          bonus_chips: integer(),
          bonus_mult: integer()
        }

  @type score_result :: %{
          hand_type: Hand.hand_type(),
          base_chips: integer(),
          base_multiplier: integer(),
          card_breakdowns: list(card_breakdown()),
          total_chips: integer(),
          total_multiplier: integer(),
          total_score: integer()
        }

  @base_hand_scores %{
    high_card: %{chips: 125, multiplier: 1},
    pair: %{chips: 140, multiplier: 1},
    two_pair: %{chips: 105, multiplier: 2},
    three_of_a_kind: %{chips: 130, multiplier: 2},
    straight: %{chips: 70, multiplier: 4},
    flush: %{chips: 70, multiplier: 4},
    full_house: %{chips: 70, multiplier: 5},
    four_of_a_kind: %{chips: 50, multiplier: 12},
    straight_flush: %{chips: 95, multiplier: 12}
  }

  @upgrade_bonuses %{
    high_card: %{chips: 10, multiplier: 1},
    pair: %{chips: 10, multiplier: 1},
    two_pair: %{chips: 10, multiplier: 1},
    three_of_a_kind: %{chips: 10, multiplier: 1},
    straight: %{chips: 10, multiplier: 1},
    flush: %{chips: 10, multiplier: 1},
    full_house: %{chips: 10, multiplier: 1},
    four_of_a_kind: %{chips: 20, multiplier: 2},
    straight_flush: %{chips: 20, multiplier: 2}
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
        base_chips: 0,
        base_multiplier: 0,
        card_breakdowns: [],
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

      # Apply bonuses to get base stats from skill tree
      base_chips = base.chips + bonus_multiplier * upgrade.chips
      base_multiplier = base.multiplier + bonus_multiplier * upgrade.multiplier

      # Build per-card breakdowns for scoring cards
      card_breakdowns =
        Enum.map(scoring_cards, fn card ->
          base_value = Card.base_chip_value(card)

          {bonus_chips, bonus_mult} =
            case card.enhancement do
              {:bonus_chips, chips} -> {chips, 0}
              {:bonus_mult, mult} -> {0, mult}
              nil -> {0, 0}
            end

          %{
            card: card,
            chip_value: base_value,
            bonus_chips: bonus_chips,
            bonus_mult: bonus_mult
          }
        end)

      # Calculate totals from breakdowns
      card_value_sum =
        Enum.sum(Enum.map(card_breakdowns, fn b -> b.chip_value + b.bonus_chips end))

      enhancement_multiplier = Enum.sum(Enum.map(card_breakdowns, fn b -> b.bonus_mult end))

      total_chips = base_chips + card_value_sum
      total_multiplier = base_multiplier + enhancement_multiplier
      total_score = total_chips * total_multiplier

      %{
        hand_type: hand_type,
        base_chips: base_chips,
        base_multiplier: base_multiplier,
        card_breakdowns: card_breakdowns,
        total_chips: total_chips,
        total_multiplier: total_multiplier,
        total_score: total_score
      }
    end
  end
end
