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
  defdelegate card_chip_value(card), to: Card, as: :chip_value

  # Hand evaluation
  defdelegate evaluate_hand(hand), to: Hand, as: :evaluate

  # Scoring
  @doc """
  Scores a hand evaluation with skill tree levels and debuffs applied.
  """
  def score_hand(hand_evaluation, skill_tree, active_debuffs \\ [], card_debuffs \\ nil) do
    card_debuffs = card_debuffs || Score.default_card_debuffs()
    Score.calculate(hand_evaluation, skill_tree, active_debuffs, card_debuffs)
  end

  defdelegate base_hand_scores(), to: Score

  # Skill tree
  defdelegate new_skill_tree(), to: SkillTree, as: :new
  defdelegate upgrade_skill_tree(skill_tree, hand_type, levels), to: SkillTree, as: :upgrade
end
