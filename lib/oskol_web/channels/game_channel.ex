defmodule OskolWeb.GameChannel do
  use Phoenix.Channel
  require Logger

  alias Oskol.Game.GameServer

  @impl true
  def join("game:" <> game_id, %{"player_id" => player_id}, socket) do
    try do
      # Subscribe to game updates via PubSub
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

      # Get current game state - returns GameServerState directly
      game_server_state = GameServer.get_state(game_id)

      # Get player name from connections to register this channel process
      player_name = get_in(game_server_state.connections, [player_id, :name])

      # Register this channel process as the active connection for this player
      if player_name do
        case GameServer.rejoin_game(game_id, player_name, self()) do
          {:ok, ^player_id, _updated_state} ->
            # Successfully registered connection
            :ok

          {:error, :player_already_connected} ->
            # This is fine - player is already connected (maybe via LiveView)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to register channel connection: #{inspect(reason)}")
        end
      end

      socket =
        socket
        |> assign(:game_id, game_id)
        |> assign(:player_id, player_id)

      # Return the game state as JSON
      # Handle both lobby (game_state == nil) and active game states
      game_state_json =
        if game_server_state.game_state == nil do
          # Game hasn't started yet - return lobby state
          %{
            phase: "lobby",
            connections: game_server_state.connections,
            lobby_status: Atom.to_string(game_server_state.lobby_status)
          }
        else
          # Game is active
          serialize_game_state(game_server_state.game_state)
        end

      {:ok, %{game_state: game_state_json}, socket}
    catch
      :exit, _ ->
        {:error, %{reason: "Game not found"}}
    end
  end

  @impl true
  def join("game:" <> _game_id, _params, _socket) do
    {:error, %{reason: "player_id required"}}
  end

  # Handle player actions
  @impl true
  def handle_in("lock_in_hand", %{"cards" => cards}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    # Convert JSON card maps to Card structs
    card_structs = Enum.map(cards, &json_to_card/1)

    GameServer.lock_in_hand_async(game_id, player_id, card_structs)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("discard_cards", %{"cards" => cards}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    # Convert JSON card maps to Card structs
    card_structs = Enum.map(cards, &json_to_card/1)

    GameServer.discard_cards_async(game_id, player_id, card_structs)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("ready_for_next_round", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.mark_ready_for_next_round_async(game_id, player_id)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("make_shop_pick", %{"card_index" => card_index}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.make_shop_pick_async(game_id, player_id, card_index)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("confirm_deck_builder_pick", %{"card_index" => card_index}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.confirm_deck_builder_pick_async(game_id, player_id, card_index)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_deck_builder_selection", %{"card_ids" => card_ids}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.complete_deck_builder_selection_async(game_id, player_id, card_ids)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("skip_deck_builder_selection", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.skip_deck_builder_selection_async(game_id, player_id)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("confirm_plus_bomb_pick", %{"card_index" => card_index}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.confirm_plus_bomb_pick_async(game_id, player_id, card_index)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_plus_bomb_selection", %{"card_id" => card_id}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.complete_plus_bomb_selection_async(game_id, player_id, card_id)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("destroy_shop_card", %{"card_index" => card_index}, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.destroy_shop_card_async(game_id, player_id, card_index)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("complete_destroy_phase", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    GameServer.complete_destroy_phase_async(game_id, player_id)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("request_rematch", _params, socket) do
    game_id = socket.assigns.game_id
    player_id = socket.assigns.player_id

    # Mark player as ready for rematch
    GameServer.mark_ready_for_next_round_async(game_id, player_id)

    # Get current game state to check if both players are ready
    game_server_state = GameServer.get_state(game_id)

    # If game is over and both players are ready, trigger rematch
    if game_server_state.game_state != nil and
       game_server_state.game_state.game_status == :game_over and
       both_players_ready_for_rematch?(game_server_state.game_state) do
      # Generate rematch game ID
      rematch_game_id = generate_rematch_id(game_id)

      # Get player names and game settings from current game
      player_names = game_server_state.game_state.player_names |> Map.values() |> Enum.to_list()
      initial_lives = game_server_state.game_state.initial_lives
      shop_rounds = game_server_state.game_state.shop_rounds

      # Determine format based on settings
      format = config_to_format(initial_lives, shop_rounds)

      # Start the new game server
      case Oskol.Game.GameSupervisor.start_game(rematch_game_id) do
        {:ok, _pid} ->
          # Join both players to the new game (PIDs will be set when they actually connect)
          [player1_name, player2_name] = player_names
          {:ok, player1_id, _} = GameServer.join_game(rematch_game_id, player1_name)
          {:ok, player2_id, _} = GameServer.join_game(rematch_game_id, player2_name)

          # Select format for both players
          _ = GameServer.select_format(rematch_game_id, player1_id, format)
          _ = GameServer.select_format(rematch_game_id, player2_id, format)

          # Start the game immediately
          _ = GameServer.start_game(rematch_game_id, [])
          :ok

        {:error, {:already_started, _pid}} ->
          # Game already exists, that's fine
          :ok
      end

      # Broadcast rematch_ready event to redirect clients
      Phoenix.PubSub.broadcast(
        Oskol.PubSub,
        "game:#{game_id}",
        {:rematch_ready, rematch_game_id}
      )
    end

    {:reply, :ok, socket}
  end

  # Handle PubSub broadcasts from GameServer
  @impl true
  def handle_info({:game_state_updated, game_server_state}, socket) do
    game_state_json =
      if game_server_state.game_state == nil do
        %{
          phase: "lobby",
          connections: game_server_state.connections,
          lobby_status: Atom.to_string(game_server_state.lobby_status)
        }
      else
        serialize_game_state(game_server_state.game_state)
      end

    push(socket, "game_state_updated", %{game_state: game_state_json})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:action_failed, _player_id, reason}, socket) do
    # Log the failure but don't crash the channel
    Logger.warning("Action failed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:rematch_ready, rematch_game_id}, socket) do
    # Notify client to navigate to rematch game
    push(socket, "rematch_ready", %{game_id: rematch_game_id})
    {:noreply, socket}
  end

  # Serialize game state to JSON-friendly format
  defp serialize_game_state(game_state) do
    # Convert game state to JSON-friendly map
    %{
      round_number: game_state.round_number,
      player_names: game_state.player_names,
      players: serialize_players(game_state.players),
      phase: serialize_phase(game_state.phase),
      game_status: serialize_game_status(game_state.game_status),
      last_hand_results: serialize_hand_results(game_state.last_hand_results),
      round_hand_history: Enum.map(game_state.round_hand_history, &serialize_hand_results/1),
      winner_id: game_state.winner_id,
      last_round_winner_id: game_state.last_round_winner_id,
      shop_state: serialize_shop_state(game_state.shop_state),
      shop_rounds: game_state.shop_rounds,
      initial_lives: game_state.initial_lives,
      hands_per_round: game_state.hands_per_round,
      discards_per_round: game_state.discards_per_round
    }
  end

  defp serialize_phase(:playing), do: "playing"
  defp serialize_phase(:round_end), do: "round_end"

  defp serialize_game_status(:active), do: "active"
  defp serialize_game_status(:game_over), do: "game_over"

  defp serialize_players(players) do
    Map.new(players, fn {player_id, player_state} ->
      {player_id, serialize_player_state(player_state)}
    end)
  end

  defp serialize_player_state(player_state) do
    %{
      player_id: player_state.player_id,
      lives: player_state.lives,
      card_piles: serialize_card_piles(player_state.card_piles),
      skill_tree: serialize_skill_tree(player_state.skill_tree),
      hands_remaining: player_state.hands_remaining,
      discards_remaining: player_state.discards_remaining,
      current_round_score: player_state.current_round_score,
      locked_in_hand: serialize_cards(player_state.locked_in_hand),
      ready_for_next_round: player_state.ready_for_next_round,
      status: serialize_player_status(player_state.status),
      active_debuffs: Enum.map(player_state.active_debuffs, &Atom.to_string/1),
      scrambled: player_state.scrambled,
      face_down_card_ids: player_state.face_down_card_ids,
      disabled_ranks: player_state.disabled_ranks,
      disabled_suits: Enum.map(player_state.disabled_suits, &Atom.to_string/1),
      enhancements_disabled: player_state.enhancements_disabled,
      supply_chain_limited: player_state.supply_chain_limited
    }
  end

  defp serialize_player_status(:active), do: "active"
  defp serialize_player_status(:eliminated), do: "eliminated"

  defp serialize_card_piles(card_piles) do
    %{
      hand_pile: serialize_cards(card_piles.hand_pile),
      draw_pile: serialize_cards(card_piles.draw_pile),
      discard_pile: serialize_cards(card_piles.discard_pile)
    }
  end

  defp serialize_cards(nil), do: nil

  defp serialize_cards(cards) when is_list(cards) do
    Enum.map(cards, &serialize_card/1)
  end

  defp serialize_card(card) when is_map(card) do
    # Handle both Card structs (atom keys) and JSON maps (string keys)
    # Use Map.get which works for both structs and plain maps
    id = Map.get(card, :id) || Map.get(card, "id")
    rank = Map.get(card, :rank) || Map.get(card, "rank")
    suit = Map.get(card, :suit) || Map.get(card, "suit")
    enhancement = Map.get(card, :enhancement) || Map.get(card, "enhancement")

    %{
      id: id,
      rank: rank,
      suit: if(is_atom(suit), do: Atom.to_string(suit), else: suit),
      enhancement: serialize_enhancement(enhancement)
    }
  end

  defp serialize_enhancement(nil), do: nil

  # Handle tuple format (from Elixir structs)
  defp serialize_enhancement({:bonus_chips, amount}) do
    %{type: "bonus_chips", amount: amount}
  end

  defp serialize_enhancement({:bonus_mult, amount}) do
    %{type: "bonus_mult", amount: amount}
  end

  # Handle map format (from JSON)
  defp serialize_enhancement(%{"type" => type, "amount" => amount}) do
    %{type: type, amount: amount}
  end

  defp serialize_enhancement(%{type: type, amount: amount}) do
    %{type: to_string(type), amount: amount}
  end

  defp serialize_skill_tree(skill_tree) do
    %{
      high_card: skill_tree.high_card,
      pair: skill_tree.pair,
      two_pair: skill_tree.two_pair,
      three_of_a_kind: skill_tree.three_of_a_kind,
      straight: skill_tree.straight,
      flush: skill_tree.flush,
      full_house: skill_tree.full_house,
      four_of_a_kind: skill_tree.four_of_a_kind,
      straight_flush: skill_tree.straight_flush
    }
  end

  defp serialize_hand_results(nil), do: nil

  defp serialize_hand_results(results) when is_map(results) do
    Map.new(results, fn {player_id, result} ->
      {player_id,
       %{
         hand: serialize_cards(result.hand),
         hand_type: Atom.to_string(result.hand_type),
         score: result.score,
         score_breakdown: serialize_score_breakdown(result.score_breakdown),
         disabled_ranks: result.disabled_ranks,
         disabled_suits: Enum.map(result.disabled_suits, &Atom.to_string/1),
         enhancements_disabled: result.enhancements_disabled
       }}
    end)
  end

  defp serialize_score_breakdown(breakdown) do
    %{
      base_chips: breakdown.base_chips,
      base_multiplier: breakdown.base_multiplier,
      total_chips: breakdown.total_chips,
      total_multiplier: breakdown.total_multiplier,
      total_score: breakdown.total_score,
      card_breakdowns: Enum.map(breakdown.card_breakdowns, &serialize_card_breakdown/1)
    }
  end

  defp serialize_card_breakdown(card_breakdown) do
    %{
      card: serialize_card(card_breakdown.card),
      chip_value: card_breakdown.chip_value,
      bonus_chips: card_breakdown.bonus_chips,
      bonus_mult: card_breakdown.bonus_mult,
      disabled: card_breakdown.disabled
    }
  end

  defp serialize_shop_state(nil), do: nil

  defp serialize_shop_state(shop_state) do
    %{
      total_rounds: shop_state.total_rounds,
      current_round: shop_state.current_round,
      first_picker_id: shop_state.first_picker_id,
      second_picker_id: shop_state.second_picker_id,
      first_pick_made: shop_state.first_pick_made,
      second_pick_made: shop_state.second_pick_made,
      available_cards: Enum.map(shop_state.available_cards, &serialize_shop_card/1),
      picked_card_indices: shop_state.picked_card_indices,
      pending_deck_builder: serialize_pending_deck_builder(shop_state.pending_deck_builder),
      pending_plus_bomb: serialize_pending_plus_bomb(shop_state.pending_plus_bomb),
      destroy_phase_complete: shop_state.destroy_phase_complete,
      destroyer_id: shop_state.destroyer_id,
      destroys_allowed: shop_state.destroys_allowed,
      destroyed_card_indices: shop_state.destroyed_card_indices
    }
  end

  defp serialize_shop_card(shop_card) do
    %{
      type: Atom.to_string(shop_card.type),
      subtype: Atom.to_string(shop_card.subtype),
      name: Oskol.Game.ShopCard.card_name(shop_card),
      description: Oskol.Game.ShopCard.card_description(shop_card),
      cost: 0,
      metadata: serialize_shop_card_metadata(shop_card.metadata)
    }
  end

  defp serialize_shop_card_metadata(nil), do: nil

  defp serialize_shop_card_metadata(metadata) do
    %{
      amount: metadata[:amount],
      suit: if(metadata[:suit], do: Atom.to_string(metadata[:suit]), else: nil)
    }
  end

  defp serialize_pending_deck_builder(nil), do: nil

  defp serialize_pending_deck_builder(pending) do
    %{
      player_id: pending.player_id,
      shop_card_index: pending.shop_card_index,
      deck_builder_card: serialize_shop_card(pending.deck_builder_card),
      available_cards: serialize_cards(pending.available_cards)
    }
  end

  defp serialize_pending_plus_bomb(nil), do: nil

  defp serialize_pending_plus_bomb(pending) do
    %{
      player_id: pending.player_id,
      shop_card_index: pending.shop_card_index,
      available_cards: serialize_cards(pending.available_cards)
    }
  end

  # Convert JSON card map to Card struct
  defp json_to_card(card_map) when is_map(card_map) do
    # Handle both string keys (from JSON) and atom keys (from Elixir)
    id = Map.get(card_map, "id") || Map.get(card_map, :id)
    rank = Map.get(card_map, "rank") || Map.get(card_map, :rank)
    suit_str = Map.get(card_map, "suit") || Map.get(card_map, :suit)
    enhancement = Map.get(card_map, "enhancement") || Map.get(card_map, :enhancement)

    # Convert suit string to atom if needed
    suit = if is_binary(suit_str), do: String.to_atom(suit_str), else: suit_str

    # Convert enhancement if present
    enhancement_tuple = case enhancement do
      nil -> nil
      %{"type" => "bonus_chips", "amount" => amount} -> {:bonus_chips, amount}
      %{"type" => "bonus_mult", "amount" => amount} -> {:bonus_mult, amount}
      %{type: "bonus_chips", amount: amount} -> {:bonus_chips, amount}
      %{type: "bonus_mult", amount: amount} -> {:bonus_mult, amount}
      other -> other  # Already in tuple format
    end

    %Oskol.Poker.Card{
      id: id,
      rank: rank,
      suit: suit,
      enhancement: enhancement_tuple
    }
  end

  # Check if both players are ready for rematch
  defp both_players_ready_for_rematch?(game_state) do
    game_state.players
    |> Map.values()
    |> Enum.all?(& &1.ready_for_next_round)
  end

  # Generate deterministic rematch game ID
  defp generate_rematch_id(current_id) do
    case Regex.run(~r/^(.+)-r(\d+)$/, current_id) do
      [_, base, num_str] ->
        num = String.to_integer(num_str)
        "#{base}-r#{num + 1}"
      nil ->
        "#{current_id}-r1"
    end
  end

  # Convert game configuration to format
  defp config_to_format(2, 1), do: :short
  defp config_to_format(3, 2), do: :standard
  defp config_to_format(5, 2), do: :extended
  # Default to standard if not a standard format
  defp config_to_format(_, _), do: :standard
end
