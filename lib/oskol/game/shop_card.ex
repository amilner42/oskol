defmodule Oskol.Game.ShopCard do
  @moduledoc """
  Consolidated shop card module that handles all types of shop cards:
  - Level up cards (hand upgrades)
  - Deck builder cards (card modifications)
  - Sabotage cards (temporary offensive effects)
  - Denial cards (hand blockers)

  Each card has:
  - Type: :level_up, :deck_builder, :sabotage, :denial
  - SubType: specific variant (e.g., :two_pair, :scrambler, :change_suit)
  - Metadata: additional info if needed (e.g., suit for change_suit, amount for bonuses)
  """

  alias Oskol.Poker.Card
  alias OskolWeb.Utils.Format

  @type hand_type ::
          :high_card
          | :pair
          | :two_pair
          | :three_of_a_kind
          | :straight
          | :flush
          | :full_house
          | :four_of_a_kind
          | :straight_flush

  @type card_type :: :level_up | :deck_builder | :sabotage | :denial

  @type subtype ::
          hand_type()
          | :scrambler
          | :plus_bomb
          | :static
          | :supply_chain
          | :bonus_chips
          | :bonus_mult
          | :add_card
          | :remove_card
          | :change_suit
          | :increase_rank

  @type metadata :: %{
          optional(:suit) => Card.suit(),
          optional(:amount) => pos_integer()
        }

  @type t :: %__MODULE__{
          type: card_type(),
          subtype: subtype(),
          metadata: metadata()
        }

  defstruct [:type, :subtype, metadata: %{}]

  # ===== Card Creation Functions =====

  @doc """
  Returns all available level up cards (one for each hand type).
  """
  def all_level_up_cards do
    [
      %__MODULE__{type: :level_up, subtype: :high_card},
      %__MODULE__{type: :level_up, subtype: :pair},
      %__MODULE__{type: :level_up, subtype: :two_pair},
      %__MODULE__{type: :level_up, subtype: :three_of_a_kind},
      %__MODULE__{type: :level_up, subtype: :straight},
      %__MODULE__{type: :level_up, subtype: :flush},
      %__MODULE__{type: :level_up, subtype: :full_house},
      %__MODULE__{type: :level_up, subtype: :four_of_a_kind},
      %__MODULE__{type: :level_up, subtype: :straight_flush}
    ]
  end

  @doc """
  Returns all available denial cards (one for each hand type).
  """
  def all_denial_cards do
    [
      %__MODULE__{type: :denial, subtype: :high_card},
      %__MODULE__{type: :denial, subtype: :pair},
      %__MODULE__{type: :denial, subtype: :two_pair},
      %__MODULE__{type: :denial, subtype: :three_of_a_kind},
      %__MODULE__{type: :denial, subtype: :straight},
      %__MODULE__{type: :denial, subtype: :flush},
      %__MODULE__{type: :denial, subtype: :full_house},
      %__MODULE__{type: :denial, subtype: :four_of_a_kind},
      %__MODULE__{type: :denial, subtype: :straight_flush}
    ]
  end

  @doc """
  Returns all available deck builder cards.
  """
  def all_deck_builder_cards do
    [
      %__MODULE__{type: :deck_builder, subtype: :bonus_chips, metadata: %{amount: 40}},
      %__MODULE__{type: :deck_builder, subtype: :bonus_mult, metadata: %{amount: 1}},
      %__MODULE__{type: :deck_builder, subtype: :add_card},
      %__MODULE__{type: :deck_builder, subtype: :remove_card},
      %__MODULE__{type: :deck_builder, subtype: :change_suit, metadata: %{suit: :hearts}},
      %__MODULE__{type: :deck_builder, subtype: :change_suit, metadata: %{suit: :diamonds}},
      %__MODULE__{type: :deck_builder, subtype: :change_suit, metadata: %{suit: :clubs}},
      %__MODULE__{type: :deck_builder, subtype: :change_suit, metadata: %{suit: :spades}},
      %__MODULE__{type: :deck_builder, subtype: :increase_rank}
    ]
  end

  @doc """
  Returns sabotage card variants.
  """
  def scrambler_card, do: %__MODULE__{type: :sabotage, subtype: :scrambler}
  def plus_bomb_card, do: %__MODULE__{type: :sabotage, subtype: :plus_bomb}
  def static_card, do: %__MODULE__{type: :sabotage, subtype: :static}
  def supply_chain_card, do: %__MODULE__{type: :sabotage, subtype: :supply_chain}

  # ===== Card Display Functions =====

  @doc """
  Returns the UI color for the card type.
  """
  @spec card_color(t()) :: String.t()
  def card_color(%__MODULE__{type: :level_up}), do: "emerald"
  def card_color(%__MODULE__{type: :deck_builder}), do: "violet"
  def card_color(%__MODULE__{type: :sabotage}), do: "amber"
  def card_color(%__MODULE__{type: :denial}), do: "rose"

  @doc """
  Returns the UI type label for the card.
  """
  @spec card_type_label(t()) :: String.t()
  def card_type_label(%__MODULE__{type: :level_up}), do: "Research"
  def card_type_label(%__MODULE__{type: :deck_builder}), do: "Logistics"
  def card_type_label(%__MODULE__{type: :sabotage}), do: "Sabotage"
  def card_type_label(%__MODULE__{type: :denial}), do: "Counter"

  @doc """
  Returns a human-readable name for the card.
  """
  @spec card_name(t()) :: String.t()
  def card_name(%__MODULE__{type: :level_up, subtype: hand_type}) do
    Format.hand_name(hand_type)
  end

  def card_name(%__MODULE__{type: :denial, subtype: hand_type}) do
    Format.hand_name(hand_type)
  end

  def card_name(%__MODULE__{type: :sabotage, subtype: :scrambler}), do: "The Scrambler"
  def card_name(%__MODULE__{type: :sabotage, subtype: :plus_bomb}), do: "Plus Bomb"
  def card_name(%__MODULE__{type: :sabotage, subtype: :static}), do: "Static Field"
  def card_name(%__MODULE__{type: :sabotage, subtype: :supply_chain}), do: "Supply Chain"

  def card_name(%__MODULE__{
        type: :deck_builder,
        subtype: :bonus_chips,
        metadata: %{amount: amt}
      }),
      do: "+#{amt} Chips"

  def card_name(%__MODULE__{type: :deck_builder, subtype: :bonus_mult, metadata: %{amount: amt}}),
    do: "+#{amt} Mult"

  def card_name(%__MODULE__{type: :deck_builder, subtype: :add_card}), do: "Add Card"
  def card_name(%__MODULE__{type: :deck_builder, subtype: :remove_card}), do: "Remove Cards"

  def card_name(%__MODULE__{
        type: :deck_builder,
        subtype: :change_suit,
        metadata: %{suit: :hearts}
      }),
      do: "Change to ♥"

  def card_name(%__MODULE__{
        type: :deck_builder,
        subtype: :change_suit,
        metadata: %{suit: :diamonds}
      }),
      do: "Change to ♦"

  def card_name(%__MODULE__{
        type: :deck_builder,
        subtype: :change_suit,
        metadata: %{suit: :clubs}
      }),
      do: "Change to ♣"

  def card_name(%__MODULE__{
        type: :deck_builder,
        subtype: :change_suit,
        metadata: %{suit: :spades}
      }),
      do: "Change to ♠"

  def card_name(%__MODULE__{type: :deck_builder, subtype: :increase_rank}), do: "Increase Rank"

  @doc """
  Returns a description of what the card does.
  """
  @spec card_description(t()) :: String.t()
  def card_description(%__MODULE__{type: :level_up, subtype: hand_type}) do
    "Upgrade #{Format.hand_name(hand_type)} - increases chips and multiplier"
  end

  def card_description(%__MODULE__{type: :denial, subtype: hand_type}) do
    "Opponent's #{Format.hand_name(hand_type)} scores 0 next round"
  end

  def card_description(%__MODULE__{type: :sabotage, subtype: :scrambler}) do
    "Opponent's drawn cards have 1-in-5 chance of being face-down next round"
  end

  def card_description(%__MODULE__{type: :sabotage, subtype: :plus_bomb}) do
    "Pick a card - opponent's matching rank/suit won't score"
  end

  def card_description(%__MODULE__{type: :sabotage, subtype: :static}) do
    "Opponent's card enhancements disabled next round"
  end

  def card_description(%__MODULE__{type: :sabotage, subtype: :supply_chain}) do
    "Opponent draws at most 4 cards when discarding next round"
  end

  def card_description(%__MODULE__{
        type: :deck_builder,
        subtype: :bonus_chips,
        metadata: %{amount: amt}
      }) do
    "Add +#{amt} chips to a card in your deck"
  end

  def card_description(%__MODULE__{
        type: :deck_builder,
        subtype: :bonus_mult,
        metadata: %{amount: amt}
      }) do
    "Add +#{amt} multiplier to a card in your deck"
  end

  def card_description(%__MODULE__{type: :deck_builder, subtype: :add_card}) do
    "Add a new card to your deck"
  end

  def card_description(%__MODULE__{type: :deck_builder, subtype: :remove_card}) do
    "Remove up to 2 cards from your deck"
  end

  def card_description(%__MODULE__{type: :deck_builder, subtype: :change_suit}) do
    "Change up to 3 cards to the selected suit"
  end

  def card_description(%__MODULE__{type: :deck_builder, subtype: :increase_rank}) do
    "Increase rank of up to 2 cards by 1 (max rank is Ace)"
  end

  @doc """
  Returns true if this card requires a card selection phase.
  """
  @spec requires_selection?(t()) :: boolean()
  def requires_selection?(%__MODULE__{type: :sabotage, subtype: :plus_bomb}), do: true
  def requires_selection?(%__MODULE__{type: :deck_builder}), do: true
  def requires_selection?(%__MODULE__{}), do: false

  @doc """
  Returns the maximum number of cards that can be selected for this card.
  Returns 1 for cards that don't support multi-select.
  """
  @spec max_selection(t()) :: pos_integer()
  def max_selection(%__MODULE__{type: :deck_builder, subtype: :change_suit}), do: 3
  def max_selection(%__MODULE__{type: :deck_builder, subtype: :remove_card}), do: 2
  def max_selection(%__MODULE__{type: :deck_builder, subtype: :increase_rank}), do: 2
  def max_selection(%__MODULE__{type: :sabotage, subtype: :plus_bomb}), do: 1
  def max_selection(%__MODULE__{type: :deck_builder}), do: 1
  def max_selection(%__MODULE__{}), do: 1

  @doc """
  Returns the selection instruction text for this card.
  """
  @spec selection_instruction(t()) :: String.t()
  def selection_instruction(%__MODULE__{type: :deck_builder, subtype: :remove_card}),
    do: "Select up to 2 cards to remove"

  def selection_instruction(%__MODULE__{type: :deck_builder, subtype: :change_suit}),
    do: "Select up to 3 cards to change"

  def selection_instruction(%__MODULE__{type: :deck_builder, subtype: :increase_rank}),
    do: "Select up to 2 cards to upgrade"

  def selection_instruction(%__MODULE__{type: :deck_builder}),
    do: "Select a card to enhance"

  def selection_instruction(%__MODULE__{type: :sabotage, subtype: :plus_bomb}),
    do: "Select a card - that rank AND suit won't score for opponent"

  def selection_instruction(%__MODULE__{}), do: ""

  @doc """
  Generates selection cards based on the card type.
  - For deck builder enhancements/removal: Returns 8 random cards from player's deck
  - For add card: Returns 8 newly generated random cards
  - For plus bomb: Returns 8 random cards from player's deck
  """
  @spec generate_selection_cards(t(), [Card.t()]) :: [Card.t()]
  def generate_selection_cards(
        %__MODULE__{type: :deck_builder, subtype: :add_card},
        _player_deck_cards
      ) do
    # Generate 8 new random cards
    all_cards = for rank <- 2..14, suit <- [:hearts, :diamonds, :clubs, :spades], do: {rank, suit}

    all_cards
    |> Enum.shuffle()
    |> Enum.take(8)
    |> Enum.map(fn {rank, suit} -> Card.new(rank, suit) end)
  end

  def generate_selection_cards(%__MODULE__{}, player_deck_cards) do
    # For enhancements, removal, and plus bomb, sample from player's deck
    player_deck_cards
    |> Enum.shuffle()
    |> Enum.take(8)
  end
end
