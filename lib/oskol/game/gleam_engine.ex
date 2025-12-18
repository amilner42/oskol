defmodule Oskol.Game.GleamEngine do
  @moduledoc """
  Elixir wrapper for the Gleam game engine.

  This module handles all conversions between Elixir and Gleam data structures.
  The game logic is 100% in Gleam - Elixir is just glue.
  """

  # No longer need Card or GleamPoker - working directly with Gleam cards

  # ========== GAME INITIALIZATION ==========

  @doc """
  Create a new game with Gleam engine.
  Gleam handles all game logic including deck creation and shuffling.
  All parameters are required - no defaults to avoid bugs.
  """
  def new_game(player_names, initial_lives, hands_per_round, discards_per_round, shop_rounds) do
    # Convert player names to Gleam dict
    gleam_player_names = player_names_to_gleam(player_names)

    # Call Gleam to create the game (Gleam will shuffle decks internally)
    :game@engine.new_game(
      gleam_player_names,
      initial_lives,
      hands_per_round,
      discards_per_round,
      shop_rounds
    )
  end

  @doc """
  Generate 16 shop cards: 8 arsenal + 8 action cards.
  Gleam handles the weighted pools and shuffling.
  """
  def generate_shop_cards do
    :shop@generator.generate_shop_cards()
  end

  # ========== ACTION HANDLING ==========

  @doc """
  Apply a game action and get back new state + events.

  New format: {player_id, action} where action is:
  - {:lock_in_hand, cards}
  - {:discard_cards, cards}
  - {:make_shop_pick, card_id}
  - {:destroy_shop_card, card_id}
  - :complete_destroy_phase
  """
  def apply_action(gleam_state, {player_id, action}) do
    gleam_action = action_to_gleam(player_id, action)

    # Call Gleam engine
    {:engine_result, new_gleam_state, gleam_events} =
      :game@engine.apply_action(gleam_state, gleam_action)

    # Events are stored in Gleam's GameState.event_log, no need to convert
    # Return them anyway for backward compatibility (game_server_state ignores them)
    {new_gleam_state, gleam_events}
  end

  # ========== CONVERSIONS TO GLEAM ==========

  defp action_to_gleam(player_id, {:lock_in_hand, cards}) do
    # Cards are already in Gleam format from game_channel
    {:lock_in_hand, player_id, cards}
  end

  defp action_to_gleam(player_id, {:discard_cards, cards}) do
    # Cards are already in Gleam format from game_channel
    {:discard_cards, player_id, cards}
  end

  defp action_to_gleam(player_id, {:upgrade_hand, hand_type, levels}) do
    {:upgrade_hand, player_id, hand_type, levels}
  end

  defp action_to_gleam(player_id, :mark_ready_for_rematch) do
    {:mark_ready_for_rematch, player_id}
  end

  defp action_to_gleam(player_id, :clear_animation) do
    {:clear_animation, player_id}
  end

  # Shop actions
  defp action_to_gleam(player_id, {:make_shop_pick, card_id}) do
    {:make_shop_pick, player_id, card_id}
  end

  defp action_to_gleam(player_id, {:destroy_shop_card, card_id}) do
    {:destroy_shop_card, player_id, card_id}
  end

  defp action_to_gleam(player_id, :complete_destroy_phase) do
    {:complete_destroy_phase, player_id}
  end

  # Multi-step shop actions
  defp action_to_gleam(player_id, {:confirm_deck_builder_pick, card_id}) do
    {:confirm_deck_builder_pick, player_id, card_id}
  end

  defp action_to_gleam(player_id, {:complete_deck_builder_selection, card_ids}) do
    {:complete_deck_builder_selection, player_id, card_ids}
  end

  defp action_to_gleam(player_id, {:confirm_plus_bomb_pick, card_id}) do
    {:confirm_plus_bomb_pick, player_id, card_id}
  end

  defp action_to_gleam(player_id, {:complete_plus_bomb_selection, opponent_card_id}) do
    {:complete_plus_bomb_selection, player_id, opponent_card_id}
  end

  defp player_names_to_gleam(player_names) do
    player_names
    |> Map.to_list()
    |> :gleam@dict.from_list()
  end

  # ========== STATE QUERIES ==========

  @doc """
  Get all players from Gleam state (for UI - used by rematch logic).
  """
  def get_players(gleam_state) do
    {:game_state, _round, _names, players_dict, _phase, _status, _last_hand, _history, _winner,
     _last_winner, _lives, _hands, _discards, _shop_rounds, _event_log, _shop_state} = gleam_state

    players_dict
    |> :gleam@dict.to_list()
    |> Enum.map(fn {player_id, gleam_player} ->
      {player_id, player_from_gleam(gleam_player)}
    end)
    |> Map.new()
  end

  defp player_from_gleam(gleam_player) do
    {:player, player_id, lives, _card_piles, _skill_tree, hands_remaining, discards_remaining,
     current_round_score, locked_in_hand, _ready_for_next_round, status, _active_debuffs,
     _scrambled, _face_down_card_ids, _disabled_ranks, _disabled_suits, _enhancements_disabled,
     _supply_chain_limited} = gleam_player

    %{
      player_id: player_id,
      lives: lives,
      hands_remaining: hands_remaining,
      discards_remaining: discards_remaining,
      current_round_score: current_round_score,
      has_locked_in:
        case locked_in_hand do
          :none -> false
          {:some, _} -> true
        end,
      status:
        case status do
          :active -> :active
          :eliminated -> :eliminated
        end
      # No longer convert hand - not needed for rematch check
    }
  end

  @doc """
  Get game phase and status.
  """
  def get_game_info(gleam_state) do
    {:game_state, round_number, _player_names, _players, phase, game_status, _last_hand_results,
     _round_hand_history, winner_id, _last_round_winner_id, _initial_lives, _hands_per_round,
     _discards_per_round, _shop_rounds, _event_log, _shop_state} = gleam_state

    %{
      round_number: round_number,
      phase:
        case phase do
          :playing -> :playing
          :round_end -> :round_end
        end,
      game_status:
        case game_status do
          :game_active -> :active
          :game_over -> :game_over
        end,
      winner_id:
        case winner_id do
          :none -> nil
          {:some, id} -> id
        end
    }
  end

  @doc """
  Check if both players are ready for rematch.
  """
  def both_players_ready_for_rematch(gleam_state) do
    :game@state.both_players_ready_for_next_round(gleam_state)
  end

  @doc """
  Get player names from Gleam state.
  Returns a map of player_id => player_name.
  """
  def get_player_names(gleam_state) do
    {:game_state, _round, player_names_dict, _players, _phase, _status, _last_hand, _history,
     _winner, _last_winner, _lives, _hands, _discards, _shop_rounds, _event_log, _shop_state} =
      gleam_state

    player_names_dict
    |> :gleam@dict.to_list()
    |> Map.new()
  end

  @doc """
  Get game configuration (initial_lives, hands_per_round, discards_per_round, shop_rounds).
  """
  def get_game_config(gleam_state) do
    {:game_state, _round, _names, _players, _phase, _status, _last_hand, _history, _winner,
     _last_winner, initial_lives, hands_per_round, discards_per_round, shop_rounds, _event_log,
     _shop_state} = gleam_state

    %{
      initial_lives: initial_lives,
      hands_per_round: hands_per_round,
      discards_per_round: discards_per_round,
      shop_rounds: shop_rounds
    }
  end

  @doc """
  Get the player-specific view for rendering.
  This is the ONLY function that should be used to send game state to Elm.
  Returns a clean, minimal view with only what that player needs to render.
  """
  def get_player_view(gleam_state, player_id) do
    gleam_view = :game@engine.get_player_view(gleam_state, player_id)

    # Extract player's skill tree from game state
    {:game_state, _round_num, _player_names, players, _phase, _game_status, _last_hand_results,
     _round_hand_history, _winner_id, _last_round_winner_id, _initial_lives, _hands_per_round,
     _discards_per_round, _shop_rounds, _event_log, _shop_state} = gleam_state

    # Get player's skill tree
    {:ok,
     {:player, _id, _lives, _card_piles, skill_tree, _hands_rem, _discards_rem, _score,
      _locked_hand, _ready_for_next_round, _status, _debuffs, _scrambled, _face_down,
      _disabled_ranks, _disabled_suits, _enh_disabled, _supply_chain}} =
      :gleam@dict.get(players, player_id)

    player_skill_tree = skill_tree_to_json_map(skill_tree)

    player_view_from_gleam(gleam_view, player_skill_tree)
  end

  # ========== PLAYER VIEW CONVERSIONS ==========

  defp player_view_from_gleam({:playing_view, playing_data}, your_skill_tree) do
    {:playing_data, your_name, your_hand, your_draw_pile, your_lives, your_hands_rem,
     your_discard_rem, your_score, your_locked_hand, your_face_down, your_disabled_ranks,
     your_disabled_suits, your_enh_disabled, your_debuffs, your_scrambled, your_supply_chain,
     opp_name, opp_hand, opp_lives, opp_hands_rem, opp_discard_rem, opp_score, opp_locked_hand,
     opp_face_down, opp_disabled_ranks, opp_disabled_suits, opp_enh_disabled, opp_debuffs,
     opp_scrambled, opp_supply_chain, round_num, hands_per_round, discards_per_round,
     initial_lives, pending_animation} =
      playing_data

    %{
      type: "playing",
      your_name: your_name,
      your_hand: Enum.map(your_hand, &card_to_json_map/1),
      your_draw_pile: Enum.map(your_draw_pile, &card_to_json_map/1),
      your_lives: your_lives,
      your_hands_remaining: your_hands_rem,
      your_discards_remaining: your_discard_rem,
      your_current_score: your_score,
      your_locked_in_hand:
        option_from_gleam(your_locked_hand, fn cards -> Enum.map(cards, &card_to_json_map/1) end),
      your_face_down_card_ids: your_face_down,
      your_disabled_ranks: your_disabled_ranks,
      your_disabled_suits: your_disabled_suits,
      your_enhancements_disabled: your_enh_disabled,
      your_active_debuffs: your_debuffs,
      your_scrambled: your_scrambled,
      your_supply_chain_limited: your_supply_chain,
      your_skill_tree: your_skill_tree,
      opponent_name: opp_name,
      opponent_hand: Enum.map(opp_hand, &card_to_json_map/1),
      opponent_lives: opp_lives,
      opponent_hands_remaining: opp_hands_rem,
      opponent_discards_remaining: opp_discard_rem,
      opponent_current_score: opp_score,
      opponent_locked_in_hand:
        option_from_gleam(opp_locked_hand, fn cards -> Enum.map(cards, &card_to_json_map/1) end),
      opponent_face_down_card_ids: opp_face_down,
      opponent_disabled_ranks: opp_disabled_ranks,
      opponent_disabled_suits: opp_disabled_suits,
      opponent_enhancements_disabled: opp_enh_disabled,
      opponent_active_debuffs: opp_debuffs,
      opponent_scrambled: opp_scrambled,
      opponent_supply_chain_limited: opp_supply_chain,
      round_number: round_num,
      hands_per_round: hands_per_round,
      discards_per_round: discards_per_round,
      initial_lives: initial_lives,
      pending_animation: option_from_gleam(pending_animation, &hand_result_animation_from_gleam/1)
    }
  end

  defp player_view_from_gleam({:game_over_view, game_over_data}, _skill_tree) do
    {:game_over_data, your_name, opp_name, winner_name, you_won, your_lives, opp_lives,
     your_ready, opp_ready} = game_over_data

    %{
      type: "game_over",
      your_name: your_name,
      opponent_name: opp_name,
      winner_name: winner_name,
      you_won: you_won,
      your_final_lives: your_lives,
      opponent_final_lives: opp_lives,
      your_ready: your_ready,
      opponent_ready: opp_ready
    }
  end

  defp player_view_from_gleam({:shop_view, shop_data}, _skill_tree) do
    {:shop_data, shop_state, available_cards, your_player_id, your_name, your_lives,
     your_skill_tree, opp_player_id, opp_name, opp_lives, opp_skill_tree, current_round,
     total_rounds, initial_lives} = shop_data

    # Convert ShopState
    {:shop_state, _total_rounds, _current_round, first_picker_id, second_picker_id,
     first_pick_made, second_pick_made, _available_cards, picked_card_ids, pending_deck_builder,
     pending_plus_bomb, destroy_phase_complete, destroyer_id, destroys_allowed,
     destroyed_card_ids} = shop_state

    # Convert shop cards to JSON
    shop_cards_json = Enum.map(available_cards, &shop_card_to_json/1)

    %{
      type: "shop",
      shop_state: %{
        total_rounds: total_rounds,
        current_round: current_round,
        first_picker_id: first_picker_id,
        second_picker_id: second_picker_id,
        first_pick_made: first_pick_made,
        second_pick_made: second_pick_made,
        available_cards: shop_cards_json,
        picked_card_ids: picked_card_ids,
        pending_deck_builder: pending_deck_builder_to_json(pending_deck_builder),
        pending_plus_bomb: pending_plus_bomb_to_json(pending_plus_bomb),
        destroy_phase_complete: destroy_phase_complete,
        destroyer_id: option_from_gleam(destroyer_id),
        destroys_allowed: destroys_allowed,
        destroyed_card_ids: destroyed_card_ids
      },
      available_cards: shop_cards_json,
      your_player_id: your_player_id,
      your_name: your_name,
      your_lives: your_lives,
      your_skill_tree: skill_tree_from_gleam(your_skill_tree),
      opponent_player_id: opp_player_id,
      opponent_name: opp_name,
      opponent_lives: opp_lives,
      opponent_skill_tree: skill_tree_from_gleam(opp_skill_tree),
      current_round: current_round,
      total_rounds: total_rounds,
      initial_lives: initial_lives
    }
  end

  # Convert a Gleam ShopCard to JSON-encodable map
  # New structure: {:shop_card, id, kind}
  # where kind is {:research, inner} | {:counter, inner} | {:logistics, inner} | {:sabotage, inner}
  defp shop_card_to_json({:shop_card, id, kind}) do
    %{
      id: id,
      kind: encode_card_kind(kind)
    }
  end

  # Encode CardKind as [category, inner_card_array]
  defp encode_card_kind({:research, inner}), do: ["Research", encode_research_card(inner)]
  defp encode_card_kind({:counter, inner}), do: ["Counter", encode_counter_card(inner)]
  defp encode_card_kind({:logistics, inner}), do: ["Logistics", encode_logistics_card(inner)]
  defp encode_card_kind({:sabotage, inner}), do: ["Sabotage", encode_sabotage_card(inner)]

  # Encode ResearchCard
  defp encode_research_card({:level_up, hand_type}),
    do: ["LevelUp", hand_type_to_string(hand_type)]

  # Encode CounterCard
  defp encode_counter_card({:denial, hand_type}), do: ["Denial", hand_type_to_string(hand_type)]

  # Encode LogisticsCard
  defp encode_logistics_card({:fortify, amount, max_cards}), do: ["Fortify", amount, max_cards]
  defp encode_logistics_card({:amplify, amount, max_cards}), do: ["Amplify", amount, max_cards]
  defp encode_logistics_card({:supply_drop, max_cards}), do: ["SupplyDrop", max_cards]
  defp encode_logistics_card({:discharge, max_cards}), do: ["Discharge", max_cards]

  defp encode_logistics_card({:camo, suit, max_cards}),
    do: ["Camo", suit_to_string(suit), max_cards]

  defp encode_logistics_card({:promote, max_cards}), do: ["Promote", max_cards]

  # Encode SabotageCard
  defp encode_sabotage_card(:scrambler), do: ["Scrambler"]
  defp encode_sabotage_card({:plus_bomb, max_cards}), do: ["PlusBomb", max_cards]
  defp encode_sabotage_card(:static_field), do: ["StaticField"]
  defp encode_sabotage_card(:supply_chain), do: ["SupplyChain"]
  # Calculate cost for the shop card
  defp calculate_card_cost(_card_type, _subtype) do
    # Placeholder - can be enhanced with proper pricing logic
    100
  end

  defp card_type_to_string(:level_up), do: "level_up"
  defp card_type_to_string(:deck_builder), do: "deck_builder"
  defp card_type_to_string(:sabotage), do: "sabotage"
  defp card_type_to_string(:denial), do: "denial"

  # Convert subtype to string for JSON subtype field
  defp subtype_to_string({:hand_subtype, hand_type}), do: hand_type_to_string(hand_type)
  defp subtype_to_string(:bonus_chips), do: "bonus_chips"
  defp subtype_to_string(:bonus_mult), do: "bonus_mult"
  defp subtype_to_string(:add_card), do: "add_card"
  defp subtype_to_string(:remove_card), do: "remove_card"
  defp subtype_to_string(:change_suit), do: "change_suit"
  defp subtype_to_string(:increase_rank), do: "increase_rank"
  defp subtype_to_string(:scrambler), do: "scrambler"
  defp subtype_to_string(:plus_bomb), do: "plus_bomb"
  defp subtype_to_string(:static), do: "static"
  defp subtype_to_string(:supply_chain), do: "supply_chain"

  defp hand_type_to_string(:high_card), do: "high_card"
  defp hand_type_to_string(:pair), do: "pair"
  defp hand_type_to_string(:two_pair), do: "two_pair"
  defp hand_type_to_string(:three_of_a_kind), do: "three_of_a_kind"
  defp hand_type_to_string(:straight), do: "straight"
  defp hand_type_to_string(:flush), do: "flush"
  defp hand_type_to_string(:full_house), do: "full_house"
  defp hand_type_to_string(:four_of_a_kind), do: "four_of_a_kind"
  defp hand_type_to_string(:straight_flush), do: "straight_flush"

  defp suit_to_string(:hearts), do: "hearts"
  defp suit_to_string(:diamonds), do: "diamonds"
  defp suit_to_string(:clubs), do: "clubs"
  defp suit_to_string(:spades), do: "spades"

  defp metadata_to_map(:no_metadata), do: nil
  defp metadata_to_map({:with_suit, suit}), do: %{suit: suit}
  defp metadata_to_map({:with_amount, amount}), do: %{amount: amount}
  defp metadata_to_map({:with_suit_and_max, suit, max}), do: %{suit: suit, max: max}
  defp metadata_to_map({:with_amount_and_max, amount, max}), do: %{amount: amount, max: max}
  defp metadata_to_map({:with_max, max}), do: %{max: max}

  defp skill_tree_from_gleam(gleam_skill_tree) do
    {:skill_tree, high_card, pair, two_pair, three_of_a_kind, straight, flush, full_house,
     four_of_a_kind, straight_flush} = gleam_skill_tree

    %{
      high_card: high_card,
      pair: pair,
      two_pair: two_pair,
      three_of_a_kind: three_of_a_kind,
      straight: straight,
      flush: flush,
      full_house: full_house,
      four_of_a_kind: four_of_a_kind,
      straight_flush: straight_flush
    }
  end

  # Convert a Gleam card directly to a JSON-encodable map
  # ID comes from Gleam - stable across game state updates
  # Rank and suit are sent as strings (atoms) - Elm will decode them to typed constructors!
  defp card_to_json_map({:card, gleam_id, gleam_rank, gleam_suit, gleam_enhancement}) do
    %{
      # Stable UUID from Gleam
      id: gleam_id,
      # Send as atom (e.g., :two) - JSON encodes as "two"
      rank: gleam_rank,
      # Send as atom (e.g., :hearts) - JSON encodes as "hearts"
      suit: gleam_suit,
      enhancement: enhancement_to_json(gleam_enhancement)
    }
  end

  defp enhancement_to_json(:none), do: nil

  defp enhancement_to_json({:some, {:bonus_chips, amount}}),
    do: %{type: "bonus_chips", amount: amount}

  defp enhancement_to_json({:some, {:bonus_mult, amount}}),
    do: %{type: "bonus_mult", amount: amount}

  # Convert Gleam Dict(HandType, Int) to JSON map with hand type strings as keys
  defp skill_tree_to_json_map(gleam_dict) do
    # Gleam dict is a special structure, convert to Elixir map
    gleam_dict
    |> :gleam@dict.to_list()
    |> Enum.map(fn {hand_type, level} ->
      {hand_type_to_string(hand_type), level}
    end)
    |> Map.new()
  end

  defp option_from_gleam(:none), do: nil
  defp option_from_gleam({:some, value}), do: value

  defp option_from_gleam(:none, _converter), do: nil
  defp option_from_gleam({:some, value}, converter), do: converter.(value)

  # Convert HandResultAnimation from Gleam to JSON
  defp hand_result_animation_from_gleam(
         {:hand_result_animation, your_hand, your_hand_type, your_score, your_breakdown,
          your_hand_level, opp_hand, opp_hand_type, opp_score, opp_breakdown, opp_hand_level}
       ) do
    %{
      your_hand: Enum.map(your_hand, &card_to_json_map/1),
      your_hand_type: hand_type_to_string(your_hand_type),
      your_score: your_score,
      your_breakdown: score_breakdown_from_gleam(your_breakdown),
      your_hand_level: your_hand_level,
      opponent_hand: Enum.map(opp_hand, &card_to_json_map/1),
      opponent_hand_type: hand_type_to_string(opp_hand_type),
      opponent_score: opp_score,
      opponent_breakdown: score_breakdown_from_gleam(opp_breakdown),
      opponent_hand_level: opp_hand_level
    }
  end

  # Convert ScoreBreakdown from Gleam to JSON
  defp score_breakdown_from_gleam(
         {:score_breakdown, base_chips, base_mult, total_chips, total_mult, card_breakdowns}
       ) do
    %{
      base_chips: base_chips,
      base_multiplier: base_mult,
      total_chips: total_chips,
      total_multiplier: total_mult,
      card_breakdowns: Enum.map(card_breakdowns, &card_breakdown_from_gleam/1)
    }
  end

  # Convert CardBreakdown from Gleam to JSON
  defp card_breakdown_from_gleam(
         {:card_breakdown, card, chip_value, bonus_chips, bonus_mult, disabled}
       ) do
    %{
      card: card_to_json_map(card),
      chip_value: chip_value,
      bonus_chips: bonus_chips,
      bonus_mult: bonus_mult,
      disabled: disabled
    }
  end

  # Convert PendingDeckBuilder from Gleam to JSON
  defp pending_deck_builder_to_json(:none), do: nil

  defp pending_deck_builder_to_json(
         {:some,
          {:pending_deck_builder, player_id, shop_card_id, deck_builder_card, available_cards}}
       ) do
    %{
      player_id: player_id,
      shop_card_id: shop_card_id,
      deck_builder_card: shop_card_to_json(deck_builder_card),
      available_cards: Enum.map(available_cards, &card_to_json_map/1)
    }
  end

  # Convert PendingPlusBomb from Gleam to JSON
  defp pending_plus_bomb_to_json(:none), do: nil

  defp pending_plus_bomb_to_json(
         {:some, {:pending_plus_bomb, player_id, shop_card_id, available_cards}}
       ) do
    %{
      player_id: player_id,
      shop_card_id: shop_card_id,
      available_cards: Enum.map(available_cards, &card_to_json_map/1)
    }
  end
end
