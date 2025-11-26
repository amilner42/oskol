defmodule Oskol.Game.PlayerState do
  @moduledoc """
  Represents an individual player's state within a game.
  """

  alias Oskol.Game.CardPiles
  alias Oskol.Poker.{Card, SkillTree}

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

  @type t :: %__MODULE__{
          player_id: player_id(),
          lives: pos_integer(),
          card_piles: CardPiles.t(),
          skill_tree: SkillTree.t(),
          hands_remaining: non_neg_integer(),
          discards_remaining: non_neg_integer(),
          current_round_score: non_neg_integer(),
          locked_in_hand: list(Card.t()) | nil,
          ready_for_next_round: boolean(),
          status: player_status(),
          active_debuffs: [hand_type()],
          scrambled: boolean(),
          face_down_card_ids: [String.t()],
          disabled_ranks: [Card.rank()],
          disabled_suits: [Card.suit()],
          enhancements_disabled: boolean()
        }

  @type player_id :: String.t()
  @type player_status :: :active | :eliminated

  defstruct player_id: nil,
            lives: nil,
            card_piles: nil,
            skill_tree: nil,
            hands_remaining: nil,
            discards_remaining: nil,
            current_round_score: nil,
            locked_in_hand: nil,
            ready_for_next_round: nil,
            status: nil,
            active_debuffs: [],
            scrambled: false,
            face_down_card_ids: [],
            disabled_ranks: [],
            disabled_suits: [],
            enhancements_disabled: false

  @discards_per_round 3
  @hands_per_round 4

  @doc """
  Creates a new player state with a full deck and level 1 skill tree.
  Draws 8 cards into hand to start.
  """
  @spec new(player_id(), pos_integer()) :: t()
  def new(player_id, initial_lives \\ 3) do
    card_piles =
      CardPiles.new(shuffle: true)
      |> CardPiles.draw_cards(8)

    %__MODULE__{
      player_id: player_id,
      lives: initial_lives,
      card_piles: card_piles,
      skill_tree: SkillTree.new(),
      hands_remaining: @hands_per_round,
      discards_remaining: @discards_per_round,
      current_round_score: 0,
      locked_in_hand: nil,
      ready_for_next_round: false,
      status: :active
    }
  end

  @doc """
  Resets the player state for a new round.
  Resets: hands remaining, discards remaining, score, locked-in hand.
  Preserves: lives, card piles, skill tree, status, active_debuffs (applied from shop).
  Optional hands_per_round parameter allows overriding the default (for dev codes like 1HAND).
  """
  @spec reset_for_new_round(t(), pos_integer()) :: t()
  def reset_for_new_round(%__MODULE__{} = player_state, hands_per_round \\ @hands_per_round) do
    %{
      player_state
      | hands_remaining: hands_per_round,
        discards_remaining: @discards_per_round,
        current_round_score: 0,
        locked_in_hand: nil,
        ready_for_next_round: false
    }
  end

  @doc """
  Clears all active debuffs. Should be called when the round ends.
  Clears: hand type denials, disabled ranks/suits, and enhancement disabling.
  """
  @spec clear_debuffs(t()) :: t()
  def clear_debuffs(%__MODULE__{} = player_state) do
    %{
      player_state
      | active_debuffs: [],
        disabled_ranks: [],
        disabled_suits: [],
        enhancements_disabled: false
    }
  end

  @doc """
  Adds a denial debuff for a specific hand type.
  This debuff will cause the hand type to score 0 this round.
  """
  @spec add_denial_debuff(t(), hand_type()) :: t()
  def add_denial_debuff(%__MODULE__{} = player_state, hand_type) do
    %{player_state | active_debuffs: [hand_type | player_state.active_debuffs]}
  end

  @doc """
  Checks if a hand type is denied (will score 0).
  """
  @spec hand_denied?(t(), hand_type()) :: boolean()
  def hand_denied?(%__MODULE__{} = player_state, hand_type) do
    hand_type in player_state.active_debuffs
  end

  @doc """
  Sets the scrambled state for a player.
  When scrambled, newly drawn cards have a chance of being face-down.
  """
  @spec set_scrambled(t(), boolean()) :: t()
  def set_scrambled(%__MODULE__{} = player_state, scrambled) do
    %{player_state | scrambled: scrambled}
  end

  @doc """
  Clears the scrambler effect and all face-down cards.
  Should be called when the round ends.
  """
  @spec clear_scrambler(t()) :: t()
  def clear_scrambler(%__MODULE__{} = player_state) do
    %{player_state | scrambled: false, face_down_card_ids: []}
  end

  @doc """
  Adds card IDs to the face-down list.
  """
  @spec add_face_down_cards(t(), [String.t()]) :: t()
  def add_face_down_cards(%__MODULE__{} = player_state, card_ids) do
    %{player_state | face_down_card_ids: card_ids ++ player_state.face_down_card_ids}
  end

  @doc """
  Removes card IDs from the face-down list (reveals them).
  """
  @spec reveal_cards(t(), [String.t()]) :: t()
  def reveal_cards(%__MODULE__{} = player_state, card_ids) do
    remaining = player_state.face_down_card_ids -- card_ids
    %{player_state | face_down_card_ids: remaining}
  end

  @doc """
  Checks if a specific card is face-down.
  """
  @spec card_face_down?(t(), String.t()) :: boolean()
  def card_face_down?(%__MODULE__{} = player_state, card_id) do
    card_id in player_state.face_down_card_ids
  end

  @doc """
  Adds a PLUS BOMB debuff that disables cards with the given rank or suit.
  Cards matching the rank OR suit will contribute 0 chips/enhancements.
  """
  @spec add_plus_bomb_debuff(t(), Card.rank(), Card.suit()) :: t()
  def add_plus_bomb_debuff(%__MODULE__{} = player_state, rank, suit) do
    %{
      player_state
      | disabled_ranks: [rank | player_state.disabled_ranks],
        disabled_suits: [suit | player_state.disabled_suits]
    }
  end

  @doc """
  Disables all card enhancements (STATIC debuff).
  Cards will still score base chip values but bonus_chips/bonus_mult are ignored.
  """
  @spec disable_enhancements(t()) :: t()
  def disable_enhancements(%__MODULE__{} = player_state) do
    %{player_state | enhancements_disabled: true}
  end

  @doc """
  Returns the card debuffs as a map suitable for Score.calculate/4.
  """
  @spec get_card_debuffs(t()) :: Oskol.Poker.Score.card_debuffs()
  def get_card_debuffs(%__MODULE__{} = player_state) do
    %{
      disabled_ranks: player_state.disabled_ranks,
      disabled_suits: player_state.disabled_suits,
      enhancements_disabled: player_state.enhancements_disabled
    }
  end
end
