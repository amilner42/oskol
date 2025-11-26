defmodule Oskol.Poker.Card do
  @moduledoc """
  Represents a playing card with rank, suit, and a unique ID.
  """

  @type rank :: 2..14
  @type suit :: :hearts | :diamonds | :clubs | :spades
  @type enhancement :: {:bonus_chips, pos_integer()} | {:bonus_mult, pos_integer()}
  @type joker_type :: :standard | :bonus_chips | :bonus_mult
  @type acts_as :: %{rank: rank(), suit: suit()}
  @type t :: %__MODULE__{
          id: String.t(),
          rank: rank() | nil,
          suit: suit() | nil,
          enhancement: enhancement() | nil,
          joker: joker_type() | nil,
          acts_as: acts_as() | nil
        }

  defstruct [:id, :rank, :suit, enhancement: nil, joker: nil, acts_as: nil]

  @ranks [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  @suits [:hearts, :diamonds, :clubs, :spades]

  @doc """
  Creates a new card with the given rank and suit.
  Automatically generates a unique ID for the card.
  """
  @spec new(rank(), suit()) :: t()
  def new(rank, suit) when rank in @ranks and suit in @suits do
    %__MODULE__{
      id: generate_id(),
      rank: rank,
      suit: suit
    }
  end

  @doc """
  Creates a new joker card with the given type.
  Jokers have no rank or suit - they act as wildcards.
  """
  @spec new_joker(joker_type()) :: t()
  def new_joker(type \\ :standard) when type in [:standard, :bonus_chips, :bonus_mult] do
    %__MODULE__{
      id: generate_id(),
      rank: nil,
      suit: nil,
      joker: type
    }
  end

  @doc """
  Returns true if the card is a joker.
  """
  @spec joker?(t()) :: boolean()
  def joker?(%__MODULE__{joker: joker}), do: joker != nil

  @doc """
  Sets what rank/suit a joker acts as when used in a hand.
  Returns the card unchanged if not a joker.
  """
  @spec set_acts_as(t(), rank(), suit()) :: t()
  def set_acts_as(%__MODULE__{joker: joker} = card, rank, suit) when joker != nil do
    %{card | acts_as: %{rank: rank, suit: suit}}
  end

  def set_acts_as(card, _rank, _suit), do: card

  # Generates a unique ID for a card
  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Applies an enhancement to a card.
  A card can only have one enhancement at a time.
  """
  @spec enhance(t(), enhancement()) :: t()
  def enhance(card, enhancement) do
    %{card | enhancement: enhancement}
  end

  @doc """
  Returns the chip value for a card, including any bonus chips from enhancements.
  Face cards (J/Q/K) are worth 10, Ace is worth 11, numbered cards are face value.
  Jokers have 0 base chip value but may have enhancement bonuses.
  """
  @spec chip_value(t()) :: integer()
  def chip_value(%__MODULE__{enhancement: {:bonus_chips, bonus}} = card) do
    base_chip_value(card) + bonus
  end

  def chip_value(card), do: base_chip_value(card)

  @doc """
  Returns the base chip value for a card (without any enhancement bonuses).
  Face cards (J/Q/K) are worth 10, Ace is worth 11, numbered cards are face value.
  Jokers have 0 base chip value.
  """
  @spec base_chip_value(t()) :: integer()
  def base_chip_value(%__MODULE__{joker: joker}) when joker != nil, do: 0
  def base_chip_value(%__MODULE__{rank: rank}) when rank in 2..10, do: rank
  def base_chip_value(%__MODULE__{rank: 11}), do: 10
  def base_chip_value(%__MODULE__{rank: 12}), do: 10
  def base_chip_value(%__MODULE__{rank: 13}), do: 10
  def base_chip_value(%__MODULE__{rank: 14}), do: 11
end
