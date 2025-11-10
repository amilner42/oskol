defmodule Oskol.Game do
  @moduledoc """
  Facade module for game-related functionality.
  """

  alias Oskol.Game.{CardPiles, GameServer, GameState, GameSupervisor, PlayerState}

  # Type aliases
  @type game_state :: GameState.t()
  @type player_state :: PlayerState.t()
  @type player_id :: PlayerState.player_id()
  @type phase :: GameState.phase()
  @type game_status :: GameState.game_status()
  @type card_piles :: CardPiles.t()

  # GameState operations
  defdelegate new_game(player_ids), to: GameState, as: :new
  defdelegate lock_in_hand(game_state, player_id, hand), to: GameState, as: :player_lock_in_hand
  defdelegate both_players_locked_in?(game_state), to: GameState

  # PlayerState operations
  defdelegate new_player(player_id), to: PlayerState, as: :new
  defdelegate reset_player_for_round(player_state), to: PlayerState, as: :reset_for_new_round

  # CardPiles operations
  defdelegate new_card_piles(opts), to: CardPiles, as: :new
  defdelegate draw_cards(card_piles, count), to: CardPiles
  defdelegate discard_cards(card_piles, cards), to: CardPiles
  defdelegate replace_cards(card_piles, cards), to: CardPiles
  defdelegate shuffle_discard_into_draw(card_piles), to: CardPiles

  # GameSupervisor operations
  defdelegate start_game(game_id), to: GameSupervisor
  defdelegate find_game(game_id), to: GameSupervisor
  defdelegate find_or_start_game(game_id), to: GameSupervisor

  # GameServer operations
  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate rejoin_game(game_id, player_name, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate start_game_session(game_id), to: GameServer, as: :start_game
  defdelegate player_lock_in_hand(game_id, player_id, hand), to: GameServer, as: :lock_in_hand
  defdelegate player_lock_in_hand_async(game_id, player_id, hand),
    to: GameServer,
    as: :lock_in_hand_async

  defdelegate player_unlock_hand_async(game_id, player_id),
    to: GameServer,
    as: :unlock_hand_async

  defdelegate player_discard_cards_async(game_id, player_id, cards),
    to: GameServer,
    as: :discard_cards_async

  defdelegate mark_ready_for_next_round_async(game_id, player_id),
    to: GameServer,
    as: :mark_ready_for_next_round_async
end
