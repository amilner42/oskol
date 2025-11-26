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

  @doc """
  Looks up a game without starting it. Returns {:ok, pid} or :not_found.
  """
  def lookup_game(game_id) do
    case GameSupervisor.find_game(game_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> :not_found
    end
  end

  # GameServer operations
  defdelegate join_game(game_id, player_name, player_pid), to: GameServer
  defdelegate rejoin_game(game_id, player_name, player_pid), to: GameServer
  defdelegate get_server_state(game_id), to: GameServer, as: :get_state
  defdelegate select_format(game_id, player_id, format), to: GameServer

  def start_game_session(game_id, dev_codes \\ []) do
    GameServer.start_game(game_id, dev_codes)
  end

  defdelegate player_lock_in_hand(game_id, player_id, hand), to: GameServer, as: :lock_in_hand

  defdelegate player_lock_in_hand_async(game_id, player_id, hand),
    to: GameServer,
    as: :lock_in_hand_async

  defdelegate player_discard_cards_async(game_id, player_id, cards),
    to: GameServer,
    as: :discard_cards_async

  defdelegate mark_ready_for_next_round_async(game_id, player_id),
    to: GameServer,
    as: :mark_ready_for_next_round_async

  defdelegate make_shop_pick_async(game_id, player_id, upgrade_index),
    to: GameServer,
    as: :make_shop_pick_async

  defdelegate confirm_deck_builder_pick_async(game_id, player_id, shop_card_index),
    to: GameServer,
    as: :confirm_deck_builder_pick_async

  defdelegate complete_deck_builder_selection_async(game_id, player_id, selected_card_id),
    to: GameServer,
    as: :complete_deck_builder_selection_async

  defdelegate skip_deck_builder_selection_async(game_id, player_id),
    to: GameServer,
    as: :skip_deck_builder_selection_async

  defdelegate confirm_plus_bomb_pick_async(game_id, player_id, shop_card_index),
    to: GameServer,
    as: :confirm_plus_bomb_pick_async

  defdelegate complete_plus_bomb_selection_async(game_id, player_id, selected_card_id),
    to: GameServer,
    as: :complete_plus_bomb_selection_async
end
