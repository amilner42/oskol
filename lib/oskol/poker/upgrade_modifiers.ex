defmodule Oskol.Poker.UpgradeModifiers do
  @moduledoc """
  Modifiers that change poker hand evaluation rules based on upgrades.

  These modifiers allow for flexible scoring rules that can be extended
  as new upgrades are added to the game (e.g., wild cards, hopping straights, etc.).
  """

  @type t :: %__MODULE__{
          # 5-card hands can be made with only 4 cards
          straight_needs_only_4: boolean(),
          flush_needs_only_4: boolean(),
          straight_flush_needs_only_4: boolean(),

          # Straights and straight flushes can have gaps (e.g., 4-5-7-8-10 is valid)
          straight_can_hop: boolean(),
          straight_flush_can_hop: boolean()
        }

  defstruct straight_needs_only_4: false,
            flush_needs_only_4: false,
            straight_flush_needs_only_4: false,
            straight_can_hop: false,
            straight_flush_can_hop: false

  @doc """
  Creates a new set of modifiers with default values (no modifications).
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Helper to create modifiers where all 5-card hands need only 4 cards.
  Useful if you have a single upgrade that affects all three hand types.
  """
  @spec five_card_hands_need_only_4() :: t()
  def five_card_hands_need_only_4 do
    %__MODULE__{
      straight_needs_only_4: true,
      flush_needs_only_4: true,
      straight_flush_needs_only_4: true
    }
  end

  @doc """
  Helper to create modifiers where straights and straight flushes can hop.
  """
  @spec straights_can_hop() :: t()
  def straights_can_hop do
    %__MODULE__{
      straight_can_hop: true,
      straight_flush_can_hop: true
    }
  end
end
