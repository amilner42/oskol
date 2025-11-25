defmodule Oskol.Game.DeckBuilderCard do
  @moduledoc """
  Represents deck builder cards that allow players to enhance, add, or remove cards from their deck.
  """

  alias Oskol.Poker.Card

  @type card_type ::
          :bonus_chips
          | :bonus_mult
          | :add_card
          | :remove_card
          | :change_suit_hearts
          | :change_suit_diamonds
          | :change_suit_clubs
          | :change_suit_spades
          | :increase_rank
  @type t :: %__MODULE__{
          type: card_type(),
          bonus_amount: pos_integer() | nil
        }

  defstruct [:type, :bonus_amount]

  @doc """
  Returns all deck builder cards available in the game.
  - 1 chip enhancement: +40 chips
  - 1 mult enhancement: +1 multiplier
  - 1 add card variant
  - 1 remove card variant
  - 4 suit-changing variants (one per suit)
  - 1 rank increase variant
  Total: 9 deck builder cards
  """
  @spec all_deck_builder_cards() :: [t()]
  def all_deck_builder_cards do
    [
      %__MODULE__{type: :bonus_chips, bonus_amount: 40},
      %__MODULE__{type: :bonus_mult, bonus_amount: 1},
      %__MODULE__{type: :add_card, bonus_amount: nil},
      %__MODULE__{type: :remove_card, bonus_amount: nil},
      %__MODULE__{type: :change_suit_hearts, bonus_amount: nil},
      %__MODULE__{type: :change_suit_diamonds, bonus_amount: nil},
      %__MODULE__{type: :change_suit_clubs, bonus_amount: nil},
      %__MODULE__{type: :change_suit_spades, bonus_amount: nil},
      %__MODULE__{type: :increase_rank, bonus_amount: nil}
    ]
  end

  @doc """
  Generates random deck builder cards for the shop.
  Shuffles all available cards and takes the requested count.
  """
  @spec generate_random_deck_builder_cards(pos_integer()) :: [t()]
  def generate_random_deck_builder_cards(count) do
    all_deck_builder_cards()
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @doc """
  Returns a human-readable name for the card.
  """
  @spec card_name(t()) :: String.t()
  def card_name(%__MODULE__{type: :bonus_chips, bonus_amount: amount}), do: "+#{amount} Chips"
  def card_name(%__MODULE__{type: :bonus_mult, bonus_amount: amount}), do: "+#{amount} Mult"
  def card_name(%__MODULE__{type: :add_card}), do: "Add Card"
  def card_name(%__MODULE__{type: :remove_card}), do: "Remove Cards"
  def card_name(%__MODULE__{type: :change_suit_hearts}), do: "Change to ♥"
  def card_name(%__MODULE__{type: :change_suit_diamonds}), do: "Change to ♦"
  def card_name(%__MODULE__{type: :change_suit_clubs}), do: "Change to ♣"
  def card_name(%__MODULE__{type: :change_suit_spades}), do: "Change to ♠"
  def card_name(%__MODULE__{type: :increase_rank}), do: "Increase Rank"

  @doc """
  Returns a human-readable description for the card.
  """
  @spec card_description(t()) :: String.t()
  def card_description(%__MODULE__{type: :bonus_chips, bonus_amount: amount}) do
    "Add +#{amount} chips to a card in your deck"
  end

  def card_description(%__MODULE__{type: :bonus_mult, bonus_amount: amount}) do
    "Add +#{amount} multiplier to a card in your deck"
  end

  def card_description(%__MODULE__{type: :add_card}) do
    "Add a new card to your deck"
  end

  def card_description(%__MODULE__{type: :remove_card}) do
    "Remove up to 3 cards from your deck"
  end

  def card_description(%__MODULE__{type: :change_suit_hearts}) do
    "Change up to 3 cards to Hearts"
  end

  def card_description(%__MODULE__{type: :change_suit_diamonds}) do
    "Change up to 3 cards to Diamonds"
  end

  def card_description(%__MODULE__{type: :change_suit_clubs}) do
    "Change up to 3 cards to Clubs"
  end

  def card_description(%__MODULE__{type: :change_suit_spades}) do
    "Change up to 3 cards to Spades"
  end

  def card_description(%__MODULE__{type: :increase_rank}) do
    "Increase rank of up to 2 cards by 1 (max rank is Ace)"
  end

  @doc """
  Generates 8 cards for selection based on the card type.
  - For enhancements/removal: Returns 8 random cards from the player's deck
  - For add card: Returns 8 newly generated random cards
  """
  @spec generate_selection_cards(t(), [Card.t()]) :: [Card.t()]
  def generate_selection_cards(%__MODULE__{type: :add_card}, _player_deck_cards) do
    # Generate 8 new random cards
    all_cards = for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades], do: {rank, suit}

    all_cards
    |> Enum.shuffle()
    |> Enum.take(8)
    |> Enum.map(fn {rank, suit} -> Card.new(rank, suit) end)
  end

  def generate_selection_cards(%__MODULE__{type: _}, player_deck_cards) do
    # For enhancements and removal, sample from player's deck
    player_deck_cards
    |> Enum.shuffle()
    |> Enum.take(8)
  end
end
