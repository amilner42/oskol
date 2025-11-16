defmodule Oskol.Game.ShopState do
  @moduledoc """
  Manages the simple multi-round shop where winner picks first, loser picks second.
  Each round both players pick from the same pool of upgrades.
  """

  alias Oskol.Game.PlayerState

  @type player_id :: PlayerState.player_id()

  @type t :: %__MODULE__{
          total_rounds: pos_integer(),
          current_round: pos_integer(),
          first_picker_id: player_id(),
          second_picker_id: player_id(),
          first_pick_made: boolean(),
          second_pick_made: boolean()
        }

  defstruct total_rounds: 1,
            current_round: 1,
            first_picker_id: nil,
            second_picker_id: nil,
            first_pick_made: false,
            second_pick_made: false

  @doc """
  Creates a new shop state.

  ## Parameters
  - winner_id: The player who won the last round (picks first)
  - loser_id: The player who lost the last round (picks second)
  - round_was_tie: If true, randomly assign who picks first
  - total_rounds: Number of upgrade rounds (1-3)
  """
  @spec new(player_id(), player_id(), boolean(), pos_integer()) :: t()
  def new(winner_id, loser_id, round_was_tie, total_rounds) do
    # If tie, randomly pick who goes first
    {first_player, second_player} =
      if round_was_tie do
        if :rand.uniform(2) == 1 do
          {winner_id, loser_id}
        else
          {loser_id, winner_id}
        end
      else
        {winner_id, loser_id}
      end

    %__MODULE__{
      total_rounds: total_rounds,
      current_round: 1,
      first_picker_id: first_player,
      second_picker_id: second_player,
      first_pick_made: false,
      second_pick_made: false
    }
  end

  @doc """
  Returns true if both players have made their picks in the current round.
  """
  @spec both_players_picked?(t()) :: boolean()
  def both_players_picked?(%__MODULE__{} = shop_state) do
    shop_state.first_pick_made and shop_state.second_pick_made
  end

  @doc """
  Returns true if all shop rounds are complete.
  """
  @spec shop_complete?(t()) :: boolean()
  def shop_complete?(%__MODULE__{} = shop_state) do
    shop_state.current_round == shop_state.total_rounds and both_players_picked?(shop_state)
  end

  @doc """
  Records a player's pick in the current round.
  """
  @spec make_pick(t(), player_id()) :: {:ok, t()} | {:error, atom()}
  def make_pick(%__MODULE__{} = shop_state, player_id) do
    cond do
      not shop_state.first_pick_made and player_id == shop_state.first_picker_id ->
        {:ok, %{shop_state | first_pick_made: true}}

      shop_state.first_pick_made and not shop_state.second_pick_made and
          player_id == shop_state.second_picker_id ->
        {:ok, %{shop_state | second_pick_made: true}}

      true ->
        {:error, :not_your_turn}
    end
  end

  @doc """
  Advances to the next shop round.
  Should be called after both players have picked.
  """
  @spec advance_round(t()) :: t()
  def advance_round(%__MODULE__{current_round: round, total_rounds: total} = shop_state)
      when round < total do
    %{
      shop_state
      | current_round: round + 1,
        first_pick_made: false,
        second_pick_made: false
    }
  end

  def advance_round(%__MODULE__{} = shop_state) do
    # Already at final round, can't advance
    shop_state
  end
end
