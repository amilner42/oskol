defmodule Oskol.Poker.Card do
  @moduledoc """
  Represents a playing card with rank, suit, and a unique ID.
  """

  @type rank :: 2..14
  @type suit :: :hearts | :diamonds | :clubs | :spades
  @type enhancement :: {:bonus_chips, pos_integer()} | {:bonus_mult, pos_integer()}
  @type t :: %__MODULE__{
          id: String.t(),
          rank: rank(),
          suit: suit(),
          enhancement: enhancement() | nil
        }

  defstruct [:id, :rank, :suit, enhancement: nil]

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
  """
  @spec chip_value(t()) :: integer()
  def chip_value(%__MODULE__{enhancement: {:bonus_chips, bonus}} = card) do
    base_chip_value(card) + bonus
  end

  def chip_value(card), do: base_chip_value(card)

  @doc """
  Returns the base chip value for a card (without any enhancement bonuses).
  Face cards (J/Q/K) are worth 10, Ace is worth 11, numbered cards are face value.
  """
  @spec base_chip_value(t()) :: integer()
  def base_chip_value(%__MODULE__{rank: rank}) when rank in 2..10, do: rank
  def base_chip_value(%__MODULE__{rank: 11}), do: 10
  def base_chip_value(%__MODULE__{rank: 12}), do: 10
  def base_chip_value(%__MODULE__{rank: 13}), do: 10
  def base_chip_value(%__MODULE__{rank: 14}), do: 11

  @doc """
  Sorts cards by rank (descending) then by suit order.
  This is the default sorting used throughout the game.
  """
  @spec sort_by_rank([t()]) :: [t()]
  def sort_by_rank(cards) do
    Enum.sort_by(cards, fn card -> {-card.rank, suit_order(card.suit)} end)
  end

  @doc """
  Returns the numeric order for a suit (used for sorting).
  Spades = 0, Hearts = 1, Clubs = 2, Diamonds = 3
  """
  @spec suit_order(suit()) :: 0..3
  def suit_order(:spades), do: 0
  def suit_order(:hearts), do: 1
  def suit_order(:clubs), do: 2
  def suit_order(:diamonds), do: 3
end
