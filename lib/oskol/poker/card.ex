defmodule Oskol.Poker.Card do
  @moduledoc """
  Represents a playing card with rank and suit.
  """

  @type rank :: 2..14
  @type suit :: :hearts | :diamonds | :clubs | :spades
  @type t :: %__MODULE__{
          rank: rank(),
          suit: suit()
        }

  defstruct [:rank, :suit]

  @ranks [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
  @suits [:hearts, :diamonds, :clubs, :spades]

  @doc """
  Creates a new card with the given rank and suit.
  """
  @spec new(rank(), suit()) :: t()
  def new(rank, suit) when rank in @ranks and suit in @suits do
    %__MODULE__{rank: rank, suit: suit}
  end

  @doc """
  Returns the chip value for a card.
  Face cards (J/Q/K) are worth 10, Ace is worth 11, numbered cards are face value.
  """
  @spec chip_value(t()) :: integer()
  def chip_value(%__MODULE__{rank: rank}) when rank in 2..10, do: rank
  def chip_value(%__MODULE__{rank: 11}), do: 10
  def chip_value(%__MODULE__{rank: 12}), do: 10
  def chip_value(%__MODULE__{rank: 13}), do: 10
  def chip_value(%__MODULE__{rank: 14}), do: 11
end
