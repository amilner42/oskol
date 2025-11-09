defmodule Oskol.Poker.SkillTree do
  @moduledoc """
  Manages skill tree levels for poker hands.
  Each hand type can be upgraded to increase its power.
  """

  alias Oskol.Poker.Hand

  @type t :: %__MODULE__{
          high_card: pos_integer(),
          pair: pos_integer(),
          two_pair: pos_integer(),
          three_of_a_kind: pos_integer(),
          straight: pos_integer(),
          flush: pos_integer(),
          full_house: pos_integer(),
          four_of_a_kind: pos_integer(),
          straight_flush: pos_integer()
        }

  defstruct high_card: 1,
            pair: 1,
            two_pair: 1,
            three_of_a_kind: 1,
            straight: 1,
            flush: 1,
            full_house: 1,
            four_of_a_kind: 1,
            straight_flush: 1

  @doc """
  Creates a new skill tree with all hand types at level 1.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Upgrades a specific hand type by the given number of levels.
  Returns the updated skill tree.
  """
  @spec upgrade(t(), Hand.hand_type(), pos_integer()) :: t()
  def upgrade(%__MODULE__{} = skill_tree, hand_type, levels)
      when is_integer(levels) and levels > 0 do
    case hand_type do
      :high_card -> %{skill_tree | high_card: skill_tree.high_card + levels}
      :pair -> %{skill_tree | pair: skill_tree.pair + levels}
      :two_pair -> %{skill_tree | two_pair: skill_tree.two_pair + levels}
      :three_of_a_kind -> %{skill_tree | three_of_a_kind: skill_tree.three_of_a_kind + levels}
      :straight -> %{skill_tree | straight: skill_tree.straight + levels}
      :flush -> %{skill_tree | flush: skill_tree.flush + levels}
      :full_house -> %{skill_tree | full_house: skill_tree.full_house + levels}
      :four_of_a_kind -> %{skill_tree | four_of_a_kind: skill_tree.four_of_a_kind + levels}
      :straight_flush -> %{skill_tree | straight_flush: skill_tree.straight_flush + levels}
    end
  end
end
