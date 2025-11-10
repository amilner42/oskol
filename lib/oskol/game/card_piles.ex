defmodule Oskol.Game.CardPiles do
  @moduledoc """
  Manages the three piles of cards in gameplay: draw pile, hand pile, and discard pile.
  """

  alias Oskol.Poker

  @type t :: %__MODULE__{
          draw_pile: list(Poker.card()),
          hand_pile: list(Poker.card()),
          discard_pile: list(Poker.card())
        }

  defstruct draw_pile: [],
            hand_pile: [],
            discard_pile: []

  @doc """
  Creates a new CardPiles with a full 52-card deck in the draw pile.
  Pass `shuffle: true` to shuffle the deck, or `shuffle: false` for an ordered deck.
  """
  @spec new(shuffle: boolean()) :: t()
  def new(shuffle: shuffle) do
    deck =
      for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades] do
        Poker.new_card(rank, suit)
      end

    draw_pile =
      if shuffle do
        Enum.shuffle(deck)
      else
        deck
      end

    %__MODULE__{
      draw_pile: draw_pile,
      hand_pile: [],
      discard_pile: []
    }
  end

  @doc """
  Draws cards from the draw pile into the hand pile.
  If draw pile doesn't have enough cards, shuffles discard pile into draw pile first.
  Returns updated CardPiles.
  """
  @spec draw_cards(t(), non_neg_integer()) :: t()
  def draw_cards(%__MODULE__{} = piles, count) when is_integer(count) and count >= 0 do
    # Ensure we have enough cards in draw pile
    piles = ensure_draw_pile_has_cards(piles, count)

    # Draw the cards
    {drawn, remaining_draw} = Enum.split(piles.draw_pile, count)

    %{piles | draw_pile: remaining_draw, hand_pile: piles.hand_pile ++ drawn}
  end

  @doc """
  Discards specific cards from hand pile into the discard pile.
  Returns updated CardPiles.
  """
  @spec discard_cards(t(), list(Poker.card())) :: t()
  def discard_cards(%__MODULE__{} = piles, cards_to_discard) do
    # Remove cards from hand pile
    new_hand_pile = Enum.reject(piles.hand_pile, fn card -> card in cards_to_discard end)

    # Add to discard pile
    new_discard = piles.discard_pile ++ cards_to_discard

    %{piles | hand_pile: new_hand_pile, discard_pile: new_discard}
  end

  @doc """
  Replaces specific cards in hand pile: discards them and draws new cards.
  Returns updated CardPiles.
  """
  @spec replace_cards(t(), list(Poker.card())) :: t()
  def replace_cards(%__MODULE__{} = piles, cards_to_replace) do
    count = length(cards_to_replace)

    piles
    |> discard_cards(cards_to_replace)
    |> draw_cards(count)
  end

  @doc """
  Shuffles the discard pile and adds it to the draw pile.
  Returns updated CardPiles.
  """
  @spec shuffle_discard_into_draw(t()) :: t()
  def shuffle_discard_into_draw(%__MODULE__{} = piles) do
    shuffled_discard = Enum.shuffle(piles.discard_pile)
    new_draw = piles.draw_pile ++ shuffled_discard

    %{piles | draw_pile: new_draw, discard_pile: []}
  end

  # Private helper to ensure draw pile has enough cards
  defp ensure_draw_pile_has_cards(%__MODULE__{} = piles, needed) do
    available = length(piles.draw_pile)

    if available < needed and length(piles.discard_pile) > 0 do
      shuffle_discard_into_draw(piles)
    else
      piles
    end
  end
end
