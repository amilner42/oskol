defmodule OskolWeb.GameLive do
  use OskolWeb, :live_view

  alias Oskol.Game

  import OskolWeb.Components.GameLive.Lobby
  import OskolWeb.Components.GameLive.Gameplay
  import OskolWeb.Components.GameLive.Summaries
  import OskolWeb.Components.GameLive.Shop
  import OskolWeb.Components.GameLive.History

  @impl true
  def mount(%{"id" => game_id}, _session, socket) do
    # Find or start game
    {:ok, _pid} = Game.find_or_start_game(game_id)

    # Subscribe to game updates
    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

    # Get initial server state
    server_state = Game.get_server_state(game_id)

    # Check for disconnected players
    disconnected_players =
      server_state.connections
      |> Enum.filter(fn {_id, conn} -> not conn.connected end)
      |> Enum.map(fn {id, conn} -> {id, conn.name} end)

    socket =
      socket
      |> assign(
        game_id: game_id,
        server_state: server_state,
        player_id: nil,
        player_name: nil,
        joined: false,
        action_in_progress: false,
        selected_card_ids: [],
        viewing_results: false,
        viewing_round_summary: false,
        viewing_match_summary: false,
        viewing_history: false,
        viewing_deck: false,
        viewing_own_deck: true,
        viewing_levels: false,
        disconnected_players: disconnected_players,
        your_card_sort: :rank,
        opponent_card_sort: :rank,
        error: nil,
        new_card_ids: [],
        opponent_new_card_ids: [],
        last_seen_event_sequence: 0,
        acknowledged_event_sequence: 0,
        selected_lives: 3,
        selected_shop_rounds: 2,
        previewing_card_index: nil,
        deck_builder_selection: nil
      )

    # Only auto-reconnect if this is the connected mount (not the initial disconnected render)
    # This prevents reconnecting with a temporary PID that will be discarded
    socket =
      if connected?(socket) do
        case disconnected_players do
          [{player_id, player_name}] ->
            case Game.rejoin_game(game_id, player_name, self()) do
              {:ok, ^player_id, new_state} ->
                # Check if there are hand results to show
                viewing_results =
                  new_state.game_state != nil and new_state.game_state.last_hand_results != nil

                socket
                |> assign(
                  player_id: player_id,
                  player_name: player_name,
                  joined: true,
                  server_state: new_state,
                  viewing_results: viewing_results,
                  selected_lives: 3,
                  selected_shop_rounds: 2,
                  error: nil
                )

              {:error, _reason} ->
                socket
            end

          _ ->
            socket
        end
      else
        socket
      end

    {:ok, socket}
  end

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
           selected_lives: 3,
           selected_shop_rounds: 2,
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_event("join_game", %{"player_name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, error: "Name cannot be empty")}
    else
      case Game.join_game(socket.assigns.game_id, name, self()) do
        {:ok, player_id, new_state} ->
          {:noreply,
           socket
           |> assign(
             player_id: player_id,
             player_name: name,
             joined: true,
             server_state: new_state,
             selected_lives: 3,
             selected_shop_rounds: 2,
             error: nil
           )}

        {:error, :name_taken} ->
          # Name is taken - try to rejoin instead
          case Game.rejoin_game(socket.assigns.game_id, name, self()) do
            {:ok, player_id, new_state} ->
              {:noreply,
               socket
               |> assign(
                 player_id: player_id,
                 player_name: name,
                 joined: true,
                 server_state: new_state,
                 selected_lives: 3,
                 selected_shop_rounds: 2,
                 error: nil
               )}

            {:error, reason} ->
              {:noreply, assign(socket, error: format_error(reason))}
          end

        {:error, reason} ->
          {:noreply, assign(socket, error: format_error(reason))}
      end
    end
  end

  @impl true
  def handle_event("select_lives", %{"lives" => lives_str}, socket) do
    lives = String.to_integer(lives_str)
    {:noreply, assign(socket, selected_lives: lives)}
  end

  @impl true
  def handle_event("select_shop_rounds", %{"rounds" => rounds_str}, socket) do
    rounds = String.to_integer(rounds_str)
    {:noreply, assign(socket, selected_shop_rounds: rounds)}
  end

  @impl true
  def handle_event("start_game", _params, socket) do
    case Game.start_game_session(
           socket.assigns.game_id,
           socket.assigns.selected_lives,
           socket.assigns.selected_shop_rounds
         ) do
      {:ok, new_state} ->
        {:noreply, assign(socket, server_state: new_state, error: nil)}

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
    # Check if we're in round_end phase - if so, show round summary
    game_state = socket.assigns.server_state.game_state

    viewing_round_summary =
      if game_state && game_state.phase == :round_end do
        true
      else
        false
      end

    {:noreply,
     assign(socket, viewing_results: false, viewing_round_summary: viewing_round_summary)}
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
  def handle_event("confirm_deck_builder_pick", %{"card_id" => card_id}, socket) do
    # Complete the deck builder selection (applies effect)
    Game.complete_deck_builder_selection_async(
      socket.assigns.game_id,
      socket.assigns.player_id,
      card_id
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
    # Local UI state - track which card user selected from the 8-card grid
    {:noreply, assign(socket, deck_builder_selection: card_id)}
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
  def handle_event("toggle_card_sort", _params, socket) do
    new_sort = if socket.assigns.your_card_sort == :rank, do: :suit, else: :rank
    {:noreply, assign(socket, your_card_sort: new_sort, opponent_card_sort: new_sort)}
  end

  @impl true
  def handle_event("toggle_history", _params, socket) do
    {:noreply, assign(socket, viewing_history: !socket.assigns.viewing_history)}
  end

  @impl true
  def handle_event("toggle_deck", _params, socket) do
    {:noreply, assign(socket, viewing_deck: !socket.assigns.viewing_deck, viewing_own_deck: true)}
  end

  @impl true
  def handle_event("toggle_deck_view", _params, socket) do
    {:noreply, assign(socket, viewing_own_deck: !socket.assigns.viewing_own_deck)}
  end

  @impl true
  def handle_event("toggle_levels", _params, socket) do
    {:noreply, assign(socket, viewing_levels: !socket.assigns.viewing_levels)}
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
       selected_lives: Map.get(socket.assigns, :selected_lives, 3),
       selected_shop_rounds: Map.get(socket.assigns, :selected_shop_rounds, 2),
       deck_builder_selection: deck_builder_selection,
       previewing_card_index: previewing_card_index
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
  defp format_error(:game_full), do: "Game is full"
  defp format_error(:name_taken), do: "Name already taken"
  defp format_error(:player_already_connected), do: "Name already taken by a connected player"
  defp format_error(:game_already_started), do: "Game already started"
  defp format_error(:not_enough_players), do: "Need 2 players to start"
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
        <.join_screen
          server_state={@server_state}
          disconnected_players={@disconnected_players}
        />
      <% else %>
        <%= if @server_state.game_state == nil do %>
          <.lobby_screen
            player_name={@player_name}
            server_state={@server_state}
            selected_lives={@selected_lives}
            selected_shop_rounds={@selected_shop_rounds}
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
              />
          <% end %>
          
    <!-- History Modal (overlay) -->
          <%= if @server_state.game_state do %>
            <.history_modal
              viewing_history={@viewing_history}
              event_log={@server_state.event_log}
              player_names={game_state.player_names}
              player_id={@player_id}
            />
            
    <!-- Deck Modal (overlay) -->
            <.deck_modal
              viewing_deck={@viewing_deck}
              viewing_own_deck={@viewing_own_deck}
              player_state={player_state}
              opponent_state={opponent_state}
              player_name={@player_name}
              opponent_name={opponent_name}
            />
            
    <!-- Levels Modal (overlay) -->
            <.levels_modal
              viewing_levels={@viewing_levels}
              player_state={player_state}
              opponent_state={opponent_state}
              player_name={@player_name}
              opponent_name={opponent_name}
            />
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end
end
