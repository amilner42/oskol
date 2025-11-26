defmodule Oskol.Poker do
  @moduledoc """
  Facade module for poker-related functionality.
  """

  alias Oskol.Poker.{Card, Hand, Score, SkillTree}

  # Type aliases
  @type card :: Card.t()
  @type hand_type :: Hand.hand_type()
  @type hand_evaluation :: Hand.evaluation()
  @type skill_tree :: SkillTree.t()
  @type score_result :: Score.score_result()

  # Card operations
  defdelegate new_card(rank, suit), to: Card, as: :new
  defdelegate new_joker(type \\ :standard), to: Card
  defdelegate joker?(card), to: Card
  defdelegate card_chip_value(card), to: Card, as: :chip_value

  # Hand evaluation
  defdelegate evaluate_hand(hand), to: Hand, as: :evaluate
  defdelegate hand_type_name(hand_type), to: Hand

  # Scoring
  defdelegate score_hand(hand_evaluation, skill_tree, active_debuffs \\ []),
    to: Score,
    as: :calculate

  defdelegate base_hand_scores(), to: Score

  # Skill tree
  defdelegate new_skill_tree(), to: SkillTree, as: :new
  defdelegate upgrade_skill_tree(skill_tree, hand_type, levels), to: SkillTree, as: :upgrade
end
