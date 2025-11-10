defmodule Oskol.Poker.Card do
  @moduledoc """
  Represents a playing card with rank, suit, and a unique ID.
  """

  @type rank :: 2..14
  @type suit :: :hearts | :diamonds | :clubs | :spades
  @type t :: %__MODULE__{
          id: String.t(),
          rank: rank(),
          suit: suit()
        }

  defstruct [:id, :rank, :suit]

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
