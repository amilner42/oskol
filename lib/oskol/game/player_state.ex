defmodule Oskol.Game.PlayerState do
  @moduledoc """
  Represents an individual player's state within a game.
  """

  alias Oskol.Game.CardPiles
  alias Oskol.Poker.{Card, SkillTree}

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
          status: player_status()
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
            status: nil

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
  Preserves: lives, card piles, skill tree, status.
  """
  @spec reset_for_new_round(t()) :: t()
  def reset_for_new_round(%__MODULE__{} = player_state) do
    %{
      player_state
      | hands_remaining: @hands_per_round,
        discards_remaining: @discards_per_round,
        current_round_score: 0,
        locked_in_hand: nil,
        ready_for_next_round: false
    }
  end
end
