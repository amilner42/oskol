defmodule OskolWeb.GameLive do
  use OskolWeb, :live_view

  alias Oskol.Game

  import OskolWeb.Components.GameLive.Gameplay
  import OskolWeb.Components.GameLive.Summaries
  import OskolWeb.Components.GameLive.Shop

  @impl true
  def mount(%{"id" => game_id} = params, _session, socket) do
    # Find or start game
    {:ok, _pid} = Game.find_or_start_game(game_id)

    # Subscribe to game updates
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

    # Get initial server state
    server_state = Game.get_server_state(game_id)

    # Check for disconnected players who could reconnect
    disconnected_players =
      server_state.connections
      |> Enum.filter(fn {_id, conn} -> not conn.connected end)
      |> Enum.map(fn {id, conn} -> {id, conn.name} end)

    # If no game in progress, redirect to landing page with game param
    # Users should join through the landing page flow
    if server_state.game_state == nil do
      {:ok, push_navigate(socket, to: ~p"/?game=#{game_id}")}
    else
      # Check for name in URL params - if present, auto-reconnect
      name_from_url = params["name"]

      {player_id, player_name, joined, final_server_state} =
        if name_from_url && name_from_url != "" do
          case Game.rejoin_game(game_id, name_from_url, self()) do
            {:ok, pid, new_state} ->
              {pid, name_from_url, true, new_state}

            {:error, _reason} ->
              # Fall through to reconnect screen
              {nil, nil, false, server_state}
          end
        else
          # No name param - show reconnect screen
          {nil, nil, false, server_state}
        end

      socket =
        socket
        |> assign(
          game_id: game_id,
          server_state: final_server_state,
          player_id: player_id,
          player_name: player_name,
          joined: joined,
          action_in_progress: false,
          selected_card_ids: [],
          viewing_results: false,
          viewing_round_summary: false,
          viewing_match_summary: false,
          console_open: false,
          console_tab: :decks,
          viewing_own_deck: true,
          levels_view_mode: :player,
          disconnected_players: disconnected_players,
          your_card_sort: :rank,
          opponent_card_sort: :rank,
          error: nil,
          new_card_ids: [],
          opponent_new_card_ids: [],
          last_seen_event_sequence: 0,
          acknowledged_event_sequence: 0,
          previewing_card_index: nil,
          deck_builder_selection: nil,
          # Score animation state
          score_animation_phase: :idle,
          score_animation_card_index: 0,
          animation_timer_ref: nil,
          # Flag to skip animation on reconnect (first state update)
          is_initial_state_update: true
        )

      {:ok, socket}
    end
  end

  # Reconnect handler - for when a disconnected player clicks to rejoin
  @impl true
  def handle_event("rejoin_as_player", %{"player_name" => name}, socket) do
    case Game.rejoin_game(socket.assigns.game_id, name, self()) do
      {:ok, player_id, new_state} ->
        # Check if there are hand results to show
        viewing_results =
          new_state.game_state != nil and new_state.game_state.last_hand_results != nil

        {:noreply,
         socket
         |> assign(
           player_id: player_id,
           player_name: name,
           joined: true,
           server_state: new_state,
           viewing_results: viewing_results,
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("toggle_card", %{"id" => card_id}, socket) do
    selected_ids = socket.assigns.selected_card_ids

    new_selected_ids =
      if card_id in selected_ids do
        # Always allow deselecting
        List.delete(selected_ids, card_id)
      else
        # Only allow selecting if we haven't reached the limit of 5
        if length(selected_ids) < 5 do
          [card_id | selected_ids]
        else
          selected_ids
        end
      end

    {:noreply, assign(socket, selected_card_ids: new_selected_ids)}
  end

  @impl true
  def handle_event("lock_in_hand", _params, socket) do
    player_state = get_player_state(socket)
    selected_ids = socket.assigns.selected_card_ids

    # Find the actual cards by ID from hand_pile
    hand = Enum.filter(player_state.card_piles.hand_pile, fn card -> card.id in selected_ids end)

    # Validate we have 1-5 cards selected
    if length(hand) == 0 do
      {:noreply, assign(socket, error: "You must select at least 1 card")}
    else
      # Fire async action (server will validate cards are in hand)
      Game.player_lock_in_hand_async(
        socket.assigns.game_id,
        socket.assigns.player_id,
        hand
      )

      # Acknowledge all events seen so far - this clears card highlights
      {:noreply,
       assign(socket,
         action_in_progress: true,
         selected_card_ids: [],
         acknowledged_event_sequence: socket.assigns.last_seen_event_sequence,
         error: nil
       )}
    end
  end

  @impl true
  def handle_event("dismiss_results", _params, socket) do
    # Cancel any pending animation timer
    if socket.assigns.animation_timer_ref do
      Process.cancel_timer(socket.assigns.animation_timer_ref)
    end

    # Check if game is over - if so, show match summary; otherwise go straight to shop
    game_state = socket.assigns.server_state.game_state

    viewing_match_summary =
      if game_state && game_state.game_status == :game_over do
        true
      else
        false
      end

    {:noreply,
     assign(socket,
       viewing_results: false,
       viewing_round_summary: false,
       viewing_match_summary: viewing_match_summary,
       score_animation_phase: :idle,
       score_animation_card_index: 0,
       animation_timer_ref: nil
     )}
  end

  @impl true
  def handle_event("skip_score_animation", _params, socket) do
    # Cancel any pending animation timer
    if socket.assigns.animation_timer_ref do
      Process.cancel_timer(socket.assigns.animation_timer_ref)
    end

    # Jump to complete phase (shows final scores but keeps viewing_results true)
    # Schedule auto-dismiss after brief pause
    Process.send_after(self(), :auto_dismiss_results, 2000)

    {:noreply,
     assign(socket,
       score_animation_phase: :complete,
       score_animation_card_index: 0,
       animation_timer_ref: nil
     )}
  end

  @impl true
  def handle_info(:auto_dismiss_results, socket) do
    # Only auto-dismiss if still viewing results
    if socket.assigns.viewing_results do
      # Check if game is over - if so, show match summary; otherwise go straight to shop
      game_state = socket.assigns.server_state.game_state

      viewing_match_summary =
        if game_state && game_state.game_status == :game_over do
          true
        else
          false
        end

      {:noreply,
       assign(socket,
         viewing_results: false,
         viewing_round_summary: false,
         viewing_match_summary: viewing_match_summary,
         score_animation_phase: :idle,
         score_animation_card_index: 0,
         animation_timer_ref: nil
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dismiss_round_summary", _params, socket) do
    game_state = socket.assigns.server_state.game_state

    if game_state.game_status == :game_over do
      {:noreply, assign(socket, viewing_round_summary: false, viewing_match_summary: true)}
    else
      # Proceed to shop screen (if shop exists) or stay on round summary with ready status
      {:noreply, assign(socket, viewing_round_summary: false)}
    end
  end

  @impl true
  def handle_info(:auto_dismiss_round_summary, socket) do
    # Only auto-dismiss if still viewing round summary
    if socket.assigns.viewing_round_summary do
      game_state = socket.assigns.server_state.game_state

      if game_state.game_status == :game_over do
        {:noreply, assign(socket, viewing_round_summary: false, viewing_match_summary: true)}
      else
        # Proceed to shop screen (if shop exists) or stay on round summary with ready status
        {:noreply, assign(socket, viewing_round_summary: false)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:advance_score_animation, socket) do
    # Get the hand results and calculate next animation step
    game_state = socket.assigns.server_state.game_state
    hand_results = game_state && game_state.last_hand_results

    if hand_results && socket.assigns.viewing_results do
      # Get player names and IDs
      player_id = socket.assigns.player_id
      player_name = socket.assigns.player_name

      opponent_id =
        game_state.players
        |> Map.keys()
        |> Enum.find(&(&1 != player_id))

      opponent_name = game_state.player_names[opponent_id]

      # Animation order is alphabetical by name - "first" uses opponent_* phases, "second" uses player_* phases
      {first_id, second_id} =
        if player_name <= opponent_name do
          {player_id, opponent_id}
        else
          {opponent_id, player_id}
        end

      first_result = hand_results[first_id]
      second_result = hand_results[second_id]

      first_card_count = length(first_result.score_breakdown.card_breakdowns)
      second_card_count = length(second_result.score_breakdown.card_breakdowns)

      current_phase = socket.assigns.score_animation_phase
      current_index = socket.assigns.score_animation_card_index

      # Note: next_animation_step uses "opponent" for first, "player" for second
      {next_phase, next_index, delay} =
        next_animation_step(
          current_phase,
          current_index,
          first_card_count,
          second_card_count
        )

      # Schedule next step if not complete
      timer_ref =
        if next_phase != :complete do
          Process.send_after(self(), :advance_score_animation, delay)
        else
          # Animation complete, schedule auto-dismiss after brief pause
          Process.send_after(self(), :auto_dismiss_results, 2000)
          nil
        end

      {:noreply,
       assign(socket,
         score_animation_phase: next_phase,
         score_animation_card_index: next_index,
         animation_timer_ref: timer_ref
       )}
    else
      {:noreply, socket}
    end
  end

  # Animation state machine: determines next phase, card index, and delay
  defp next_animation_step(current_phase, current_index, opponent_cards, player_cards) do
    case current_phase do
      :opponent_base ->
        if opponent_cards > 0 do
          {:opponent_cards, 0, 600}
        else
          {:opponent_final, 0, 750}
        end

      :opponent_cards ->
        if current_index + 1 < opponent_cards do
          {:opponent_cards, current_index + 1, 600}
        else
          {:opponent_final, 0, 750}
        end

      :opponent_final ->
        {:player_base, 0, 750}

      :player_base ->
        if player_cards > 0 do
          {:player_cards, 0, 600}
        else
          {:player_final, 0, 750}
        end

      :player_cards ->
        if current_index + 1 < player_cards do
          {:player_cards, current_index + 1, 600}
        else
          {:player_final, 0, 750}
        end

      :player_final ->
        {:complete, 0, 0}

      _ ->
        {:complete, 0, 0}
    end
  end

  @impl true
  def handle_event("mark_ready", _params, socket) do
    Game.mark_ready_for_next_round_async(socket.assigns.game_id, socket.assigns.player_id)
    {:noreply, assign(socket, action_in_progress: true)}
  end

  @impl true
  def handle_event("make_shop_pick", %{"index" => index_str}, socket) do
    upgrade_index = String.to_integer(index_str)
    Game.make_shop_pick_async(socket.assigns.game_id, socket.assigns.player_id, upgrade_index)
    {:noreply, assign(socket, action_in_progress: true)}
  end

  @impl true
  def handle_event("preview_shop_card", %{"index" => index_str}, socket) do
    card_index = String.to_integer(index_str)

    # Broadcast preview to all players in the game
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{socket.assigns.game_id}",
      {:shop_preview_changed, card_index}
    )

    {:noreply, assign(socket, previewing_card_index: card_index)}
  end

  @impl true
  def handle_event("close_shop_preview", _params, socket) do
    # Broadcast close to all players
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{socket.assigns.game_id}",
      {:shop_preview_changed, nil}
    )

    {:noreply, assign(socket, previewing_card_index: nil)}
  end

  @impl true
  def handle_event("confirm_shop_pick", %{"index" => index_str}, socket) do
    card_index = String.to_integer(index_str)

    # Make the actual shop pick
    Game.make_shop_pick_async(socket.assigns.game_id, socket.assigns.player_id, card_index)

    # Close preview for all players
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{socket.assigns.game_id}",
      {:shop_preview_changed, nil}
    )

    {:noreply, assign(socket, action_in_progress: true, previewing_card_index: nil)}
  end

  @impl true
  def handle_event("preview_deck_builder", %{"index" => index_str}, socket) do
    card_index = String.to_integer(index_str)

    # Broadcast to sync preview with opponent's view
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{socket.assigns.game_id}",
      {:shop_preview_changed, card_index}
    )

    # Just open the modal - no server call yet
    # User will see description + "Confirm Pick" button
    {:noreply, assign(socket, previewing_card_index: card_index)}
  end

  @impl true
  def handle_event("confirm_deck_builder_preview", %{"index" => index_str}, socket) do
    card_index = String.to_integer(index_str)

    # NOW start deck builder flow (marks card as picked, generates 8 cards)
    Game.confirm_deck_builder_pick_async(
      socket.assigns.game_id,
      socket.assigns.player_id,
      card_index
    )

    {:noreply, assign(socket, action_in_progress: true, deck_builder_selection: nil)}
  end

  @impl true
  def handle_event("confirm_deck_builder_pick", %{"card_ids" => card_ids_param}, socket) do
    # Complete the deck builder selection (applies effect)
    # card_ids_param is either a single card_id string or a JSON-encoded list
    card_ids =
      case Jason.decode(card_ids_param) do
        {:ok, list} when is_list(list) -> list
        _ -> card_ids_param
      end

    Game.complete_deck_builder_selection_async(
      socket.assigns.game_id,
      socket.assigns.player_id,
      card_ids
    )

    {:noreply, assign(socket, action_in_progress: true, deck_builder_selection: nil)}
  end

  @impl true
  def handle_event("skip_deck_builder_selection", _params, socket) do
    # Skip without applying effect
    Game.skip_deck_builder_selection_async(
      socket.assigns.game_id,
      socket.assigns.player_id
    )

    {:noreply, assign(socket, action_in_progress: true, deck_builder_selection: nil)}
  end

  @impl true
  def handle_event("select_deck_card", %{"card_id" => card_id}, socket) do
    # Local UI state - track which card(s) user selected from the 8-card grid
    # For :remove_card and suit changes, allow selecting up to 3 cards
    # For other types, only allow selecting 1 card

    pending =
      with %{server_state: %{game_state: %{shop_state: shop_state}}} <- socket.assigns,
           %{pending_deck_builder: pending} when not is_nil(pending) <- shop_state do
        pending
      else
        _ -> nil
      end

    card_type = pending && pending.deck_builder_card.type

    is_multi_select =
      card_type in [
        :remove_card,
        :change_suit_hearts,
        :change_suit_diamonds,
        :change_suit_clubs,
        :change_suit_spades,
        :increase_rank
      ]

    max_cards =
      case card_type do
        :increase_rank -> 2
        :remove_card -> 2
        _ -> 3
      end

    new_selection =
      if is_multi_select do
        # Toggle card in/out of list
        current_list = socket.assigns.deck_builder_selection || []

        if card_id in current_list do
          List.delete(current_list, card_id)
        else
          if length(current_list) < max_cards do
            [card_id | current_list]
          else
            current_list
          end
        end
      else
        # Single selection for other types
        card_id
      end

    {:noreply, assign(socket, deck_builder_selection: new_selection)}
  end

  @impl true
  def handle_event("close_deck_builder_preview", _params, socket) do
    # Close preview for all players
    Phoenix.PubSub.broadcast(
      Oskol.PubSub,
      "game:#{socket.assigns.game_id}",
      {:shop_preview_changed, nil}
    )

    {:noreply, assign(socket, previewing_card_index: nil, deck_builder_selection: nil)}
  end

  @impl true
  def handle_event("toggle_your_card_sort", _params, socket) do
    new_sort = if socket.assigns.your_card_sort == :rank, do: :suit, else: :rank
    {:noreply, assign(socket, your_card_sort: new_sort)}
  end

  @impl true
  def handle_event("toggle_opponent_card_sort", _params, socket) do
    new_sort = if socket.assigns.opponent_card_sort == :rank, do: :suit, else: :rank
    {:noreply, assign(socket, opponent_card_sort: new_sort)}
  end

  @impl true
  def handle_event("toggle_console", _params, socket) do
    {:noreply, assign(socket, console_open: !socket.assigns.console_open)}
  end

  @impl true
  def handle_event("set_console_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    {:noreply, assign(socket, console_tab: tab_atom)}
  end

  @impl true
  def handle_event("view_your_deck", _params, socket) do
    {:noreply, assign(socket, viewing_own_deck: true)}
  end

  @impl true
  def handle_event("view_opponent_deck", _params, socket) do
    {:noreply, assign(socket, viewing_own_deck: false)}
  end

  @impl true
  def handle_event("view_your_levels", _params, socket) do
    {:noreply, assign(socket, levels_view_mode: :player)}
  end

  @impl true
  def handle_event("view_opponent_levels", _params, socket) do
    {:noreply, assign(socket, levels_view_mode: :opponent)}
  end

  @impl true
  def handle_event("noop", _params, socket) do
    # No-op event to prevent click propagation in modal
    {:noreply, socket}
  end

  @impl true
  def handle_event("discard_cards", _params, socket) do
    player_state = get_player_state(socket)
    selected_ids = socket.assigns.selected_card_ids

    # Find the actual cards by ID from hand_pile
    cards = Enum.filter(player_state.card_piles.hand_pile, fn card -> card.id in selected_ids end)

    # Validate discard
    cond do
      player_state.discards_remaining == 0 ->
        {:noreply, assign(socket, error: "No discards remaining")}

      length(cards) == 0 ->
        {:noreply, assign(socket, error: "You must select at least 1 card to discard")}

      true ->
        # Fire async action (server will validate cards are in hand)
        Game.player_discard_cards_async(
          socket.assigns.game_id,
          socket.assigns.player_id,
          cards
        )

        # Acknowledge all events seen so far - this clears card highlights
        {:noreply,
         assign(socket,
           action_in_progress: true,
           selected_card_ids: [],
           acknowledged_event_sequence: socket.assigns.last_seen_event_sequence,
           error: nil
         )}
    end
  end

  @impl true
  def handle_info({:game_state_updated, new_state}, socket) do
    # Check if we got new hand results - if so, show the results screen
    old_results =
      socket.assigns.server_state.game_state &&
        socket.assigns.server_state.game_state.last_hand_results

    new_results = new_state.game_state && new_state.game_state.last_hand_results

    viewing_results =
      cond do
        new_results == nil -> false
        new_results != old_results -> true
        true -> socket.assigns.viewing_results
      end

    # On reconnect (initial state update), don't show results at all - player likely already saw them
    viewing_results =
      if socket.assigns.is_initial_state_update do
        false
      else
        viewing_results
      end

    # If viewing_results just became true, start the score animation
    {animation_phase, animation_timer_ref} =
      if viewing_results && !socket.assigns.viewing_results do
        # Start animation from opponent's base stats phase
        timer_ref = Process.send_after(self(), :advance_score_animation, 750)
        {:opponent_base, timer_ref}
      else
        {socket.assigns.score_animation_phase, socket.assigns.animation_timer_ref}
      end

    # DON'T auto-show round summary when phase changes to :round_end
    # Let hand results show first, then user dismisses to see round summary
    viewing_round_summary = socket.assigns.viewing_round_summary

    # Update disconnected players list
    disconnected_players =
      new_state.connections
      |> Enum.filter(fn {_id, conn} -> not conn.connected end)
      |> Enum.map(fn {id, conn} -> {id, conn.name} end)

    # Detect new cards using event log (much more reliable than diffing state)
    alias Oskol.Game.EventLog

    {new_card_ids, opponent_new_card_ids, last_seen_sequence} =
      if socket.assigns.player_id && new_state.game_state do
        opponent_id =
          new_state.game_state.players
          |> Map.keys()
          |> Enum.find(&(&1 != socket.assigns.player_id))

        # Get all new events since last seen (for tracking)
        new_events =
          EventLog.get_since(new_state.event_log, socket.assigns.last_seen_event_sequence + 1)

        # Get events since last acknowledged (for highlighting)
        # This allows us to clear highlights on user action by updating acknowledged_event_sequence
        highlight_events =
          EventLog.get_since(new_state.event_log, socket.assigns.acknowledged_event_sequence + 1)

        # Extract card IDs from cards_drawn events for this player (from acknowledged events)
        # Exclude round_start draws - only highlight after discard/play
        player_new_cards =
          highlight_events
          |> Enum.filter(fn event ->
            event.type == :cards_drawn &&
              event.player_id == socket.assigns.player_id &&
              event.data.reason != :round_start
          end)
          |> Enum.flat_map(fn event -> Enum.map(event.data.cards, & &1.id) end)

        # Extract card IDs from cards_drawn events for opponent (from acknowledged events)
        # Exclude round_start draws - only highlight after discard/play
        opponent_new_cards =
          if opponent_id do
            highlight_events
            |> Enum.filter(fn event ->
              event.type == :cards_drawn &&
                event.player_id == opponent_id &&
                event.data.reason != :round_start
            end)
            |> Enum.flat_map(fn event -> Enum.map(event.data.cards, & &1.id) end)
          else
            []
          end

        # Get current hand card IDs to filter out cards no longer in hand
        current_hand_ids =
          case new_state.game_state.players[socket.assigns.player_id] do
            nil -> []
            player_state -> Enum.map(player_state.card_piles.hand_pile, & &1.id)
          end

        current_opponent_hand_ids =
          if opponent_id do
            case new_state.game_state.players[opponent_id] do
              nil -> []
              opponent_state -> Enum.map(opponent_state.card_piles.hand_pile, & &1.id)
            end
          else
            []
          end

        # Filter to cards still in hand (no need to combine with old, events track everything)
        new_card_ids_to_highlight =
          player_new_cards
          |> Enum.uniq()
          |> Enum.filter(&(&1 in current_hand_ids))

        opponent_new_card_ids_to_highlight =
          opponent_new_cards
          |> Enum.uniq()
          |> Enum.filter(&(&1 in current_opponent_hand_ids))

        # Update last seen sequence to latest event
        latest_sequence =
          if length(new_events) > 0 do
            List.last(new_events).sequence
          else
            socket.assigns.last_seen_event_sequence
          end

        {new_card_ids_to_highlight, opponent_new_card_ids_to_highlight, latest_sequence}
      else
        {socket.assigns.new_card_ids, socket.assigns.opponent_new_card_ids,
         socket.assigns.last_seen_event_sequence}
      end

    # Check if pending_deck_builder changed - if so, clear selection
    old_pending =
      socket.assigns.server_state.game_state &&
        socket.assigns.server_state.game_state.shop_state &&
        socket.assigns.server_state.game_state.shop_state.pending_deck_builder

    new_pending =
      new_state.game_state &&
        new_state.game_state.shop_state &&
        new_state.game_state.shop_state.pending_deck_builder

    deck_builder_selection =
      if old_pending != new_pending do
        nil
      else
        socket.assigns.deck_builder_selection
      end

    # Clear previewing_card_index if it's not your turn anymore
    previewing_card_index =
      if new_state.game_state && new_state.game_state.shop_state && socket.assigns.player_id do
        can_pick =
          Oskol.Game.ShopState.can_pick?(
            new_state.game_state.shop_state,
            socket.assigns.player_id
          )

        if can_pick do
          socket.assigns.previewing_card_index
        else
          nil
        end
      else
        socket.assigns.previewing_card_index
      end

    {:noreply,
     socket
     |> assign(
       server_state: new_state,
       action_in_progress: false,
       viewing_results: viewing_results,
       viewing_round_summary: viewing_round_summary,
       disconnected_players: disconnected_players,
       new_card_ids: new_card_ids,
       opponent_new_card_ids: opponent_new_card_ids,
       last_seen_event_sequence: last_seen_sequence,
       deck_builder_selection: deck_builder_selection,
       previewing_card_index: previewing_card_index,
       score_animation_phase: animation_phase,
       animation_timer_ref: animation_timer_ref,
       # Clear initial state flag after first update
       is_initial_state_update: false
     )
     |> clear_error()}
  end

  @impl true
  def handle_info({:action_failed, player_id, reason}, socket) do
    if player_id == socket.assigns.player_id do
      {:noreply,
       socket
       |> assign(action_in_progress: false, error: format_error(reason))
       |> put_flash(:error, format_error(reason))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:shop_preview_changed, card_index}, socket) do
    {:noreply, assign(socket, previewing_card_index: card_index)}
  end

  # Helper functions

  defp get_player_state(socket) do
    if socket.assigns.server_state.game_state do
      socket.assigns.server_state.game_state.players[socket.assigns.player_id]
    else
      nil
    end
  end

  # Helper functions

  defp format_error(:game_full), do: "Game is full"
  defp format_error(:name_taken), do: "Name already taken"
  defp format_error(:player_already_connected), do: "Name already taken by a connected player"
  defp format_error(:game_already_started), do: "Game already started"
  defp format_error(:not_enough_players), do: "Need 2 players to start"
  defp format_error(:no_format_agreement), do: "Both players must select the same format"
  defp format_error(:game_not_started), do: "Game hasn't started yet"
  defp format_error(:player_not_found), do: "Player not found"
  defp format_error(:player_disconnected), do: "You are disconnected"
  defp format_error(:no_discards_remaining), do: "No discards remaining"
  defp format_error(:invalid_discard_count), do: "Invalid discard count (1-5 cards)"
  defp format_error({:unknown_action, _}), do: "Unknown action"
  defp format_error(other), do: "Error: #{inspect(other)}"

  defp clear_error(socket), do: assign(socket, error: nil)

  # Helper functions for extracting game data from assigns

  defp get_game_data(assigns) do
    game_state = assigns.server_state.game_state

    if game_state && assigns.player_id do
      player_state = game_state.players[assigns.player_id]

      opponent_id =
        game_state.players
        |> Map.keys()
        |> Enum.find(&(&1 != assigns.player_id))

      opponent_state = if opponent_id, do: game_state.players[opponent_id], else: nil
      opponent_name = if opponent_id, do: game_state.player_names[opponent_id], else: nil

      %{
        game_state: game_state,
        player_state: player_state,
        opponent_id: opponent_id,
        opponent_state: opponent_state,
        opponent_name: opponent_name
      }
    else
      nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.card_styles />

    <div class="min-h-screen text-base-content">
      <%= if @error do %>
        <.error_banner error={@error} />
      <% end %>

      <%= if not @joined do %>
        <!-- Brief reconnect screen while determining which player to reconnect as -->
        <.reconnect_screen
          game_id={@game_id}
          disconnected_players={@disconnected_players}
        />
      <% else %>
        <% game_data = get_game_data(assigns) %>
        <% game_state = game_data.game_state %>
        <% player_state = game_data.player_state %>
        <% opponent_id = game_data.opponent_id %>
        <% opponent_state = game_data.opponent_state %>
        <% opponent_name = game_data.opponent_name %>

        <%= cond do %>
          <% @viewing_match_summary && game_state.game_status == :game_over -> %>
            <.match_summary_screen
              game_state={game_state}
              player_id={@player_id}
              opponent_id={opponent_id}
              player_name={@player_name}
              opponent_name={opponent_name}
              player_state={player_state}
              opponent_state={opponent_state}
            />
          <% @viewing_round_summary && game_state.phase == :round_end -> %>
            <.round_summary_screen
              game_state={game_state}
              player_name={@player_name}
              opponent_name={opponent_name}
              player_state={player_state}
              opponent_state={opponent_state}
            />
          <% game_state.phase == :round_end && game_state.shop_state != nil && !@viewing_results && !@viewing_round_summary && !@viewing_match_summary && game_state.game_status != :game_over -> %>
            <.shop_screen
              game_state={game_state}
              player_id={@player_id}
              player_name={@player_name}
              opponent_name={opponent_name}
              player_state={player_state}
              opponent_state={opponent_state}
              action_in_progress={@action_in_progress}
              previewing_card_index={@previewing_card_index}
              deck_builder_selection={@deck_builder_selection}
            />
          <% true -> %>
            <.game_screen
              game_state={game_state}
              player_id={@player_id}
              opponent_id={opponent_id}
              player_name={@player_name}
              opponent_name={opponent_name}
              player_state={player_state}
              opponent_state={opponent_state}
              opponent_card_sort={@opponent_card_sort}
              opponent_new_card_ids={@opponent_new_card_ids}
              selected_card_ids={@selected_card_ids}
              your_card_sort={@your_card_sort}
              new_card_ids={@new_card_ids}
              action_in_progress={@action_in_progress}
              viewing_results={@viewing_results}
              connections={@server_state.connections}
              score_animation_phase={@score_animation_phase}
              score_animation_card_index={@score_animation_card_index}
              console_open={@console_open}
              console_tab={@console_tab}
              viewing_own_deck={@viewing_own_deck}
              levels_view_mode={@levels_view_mode}
              event_log={@server_state.event_log}
            />
        <% end %>
      <% end %>
    </div>
    """
  end

  # Simple error banner
  defp error_banner(assigns) do
    ~H"""
    <div class="fixed top-4 left-1/2 -translate-x-1/2 z-50 bg-red-500/90 backdrop-blur-sm text-white px-6 py-3 rounded-xl shadow-xl">
      {@error}
    </div>
    """
  end

  # Simple reconnect screen for when multiple disconnected players exist
  defp reconnect_screen(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-base-300 via-base-200 to-base-100 px-6">
      <div class="w-full max-w-md mx-auto text-center">
        <h1 class="text-2xl font-bold text-base-content mb-6">Reconnect to Game</h1>

        <%= if length(@disconnected_players) > 0 do %>
          <div class="space-y-3">
            <%= for {_player_id, player_name} <- @disconnected_players do %>
              <button
                phx-click="rejoin_as_player"
                phx-value-player_name={player_name}
                class="relative w-full px-8 py-4 rounded-xl font-bold text-lg text-white transition-all shadow-xl overflow-hidden hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98] bg-gradient-to-r from-amber-500 to-yellow-500 hover:from-amber-600 hover:to-yellow-600"
              >
                <span class="relative z-10">Reconnect as {player_name}</span>
                <.card_decorations />
              </button>
            <% end %>
          </div>
        <% else %>
          <div class="text-base-content/60">
            Connecting...
          </div>
        <% end %>

        <p class="text-base-content/40 text-xs mt-6">
          Game: {@game_id}
        </p>
      </div>
    </div>
    """
  end

  defp card_decorations(assigns) do
    ~H"""
    <span
      class="absolute text-white/20 text-2xl"
      style="top: 8%; left: 8%; transform: rotate(-15deg);"
    >
      &#9824;
    </span>
    <span class="absolute text-white/20 text-xl" style="top: 60%; left: 5%; transform: rotate(10deg);">
      &#9830;
    </span>
    <span
      class="absolute text-white/20 text-3xl"
      style="top: 15%; right: 10%; transform: rotate(20deg);"
    >
      &#9829;
    </span>
    <span
      class="absolute text-white/20 text-xl"
      style="top: 55%; right: 8%; transform: rotate(-8deg);"
    >
      &#9827;
    </span>
    <span class="absolute text-white/20 text-lg" style="top: 35%; left: 20%; transform: rotate(5deg);">
      &#9829;
    </span>
    <span
      class="absolute text-white/20 text-2xl"
      style="top: 40%; right: 22%; transform: rotate(-12deg);"
    >
      &#9824;
    </span>
    """
  end
end
