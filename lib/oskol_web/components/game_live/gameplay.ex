defmodule OskolWeb.Components.GameLive.Gameplay do
  @moduledoc """
  Gameplay components including game screen, cards, and playing area.
  """
  use OskolWeb, :html

  alias Oskol.Poker.Card

  def card_styles(assigns) do
    ~H"""
    <style>
      .new-card {
        position: relative;
      }

      .new-card::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 4px;
        background-color: rgb(234, 179, 8);
        z-index: 10;
      }

      .new-card::after {
        content: '';
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        height: 4px;
        background-color: rgb(234, 179, 8);
        z-index: 10;
      }

      @keyframes fillProgress5s {
        0% {
          width: 0%;
        }
        100% {
          width: 100%;
        }
      }

      @keyframes fillProgress10s {
        0% {
          width: 0%;
        }
        100% {
          width: 100%;
        }
      }

      .skip-button-5s {
        position: relative;
        overflow: hidden;
      }

      .skip-button-5s::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background-color: rgba(255, 255, 255, 0.3);
        animation: fillProgress5s 5s linear forwards;
        z-index: 0;
      }

      .skip-button-10s {
        position: relative;
        overflow: hidden;
      }

      .skip-button-10s::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background-color: rgba(255, 255, 255, 0.3);
        animation: fillProgress10s 10s linear forwards;
        z-index: 0;
      }

      .skip-button-text {
        position: relative;
        z-index: 1;
      }

      /* Score animation styles */
      @keyframes borderPulse {
        0%, 100% { box-shadow: 0 0 0 3px rgba(234, 179, 8, 0.3); }
        50% { box-shadow: 0 0 15px 3px rgba(234, 179, 8, 0.8); }
      }

      .card-scoring {
        animation: borderPulse 0.4s ease-in-out;
        box-shadow: 0 0 15px 3px rgba(234, 179, 8, 0.8);
      }

      .card-scored {
        box-shadow: 0 0 0 2px rgba(234, 179, 8, 0.5);
      }

      .card-not-scoring {
        opacity: 0.4;
      }

      @keyframes chipPop {
        0% { transform: scale(1); }
        50% { transform: scale(1.2); }
        100% { transform: scale(1); }
      }

      .chip-updated {
        animation: chipPop 0.3s ease-out;
        color: rgb(234, 179, 8);
      }

      @keyframes scoreReveal {
        0% { transform: scale(0.8); opacity: 0; }
        100% { transform: scale(1); opacity: 1; }
      }

      .score-reveal {
        animation: scoreReveal 0.4s ease-out;
      }

      /* Floating chip indicator */
      @keyframes floatUp {
        0% {
          opacity: 0;
          transform: translateY(0) scale(0.8);
        }
        20% {
          opacity: 1;
          transform: translateY(-5px) scale(1);
        }
        80% {
          opacity: 1;
          transform: translateY(-15px) scale(1);
        }
        100% {
          opacity: 0;
          transform: translateY(-25px) scale(0.9);
        }
      }

      .chip-float {
        position: absolute;
        top: -8px;
        left: 50%;
        transform: translateX(-50%);
        font-weight: bold;
        font-size: 14px;
        text-shadow: 0 1px 3px rgba(0,0,0,0.5);
        animation: floatUp 0.8s ease-out forwards;
        pointer-events: none;
        white-space: nowrap;
        z-index: 20;
      }

      .chip-float-chips {
        color: #60a5fa;
      }

      .chip-float-mult {
        color: #f87171;
      }
    </style>
    """
  end

  def game_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-300">
      <!-- Top - Opponent Cards -->
      <div class="flex-1 flex flex-col justify-end p-4 bg-base-200/40">
        <.opponent_cards
          opponent_state={@opponent_state}
          opponent_card_sort={@opponent_card_sort}
          opponent_new_card_ids={@opponent_new_card_ids}
          opponent_face_down_card_ids={@opponent_face_down_card_ids}
        />
      </div>
      
    <!-- Middle - Playing Area -->
      <div class="flex-[2] flex flex-col justify-start bg-base-100 shadow-[0_0_30px_-5px_rgba(0,0,0,0.5)]">
        <.playing_area
          game_state={@game_state}
          player_id={@player_id}
          opponent_id={@opponent_id}
          player_name={@player_name}
          opponent_name={@opponent_name}
          player_state={@player_state}
          opponent_state={@opponent_state}
          viewing_results={@viewing_results}
          connections={@connections}
          score_animation_phase={@score_animation_phase}
          score_animation_card_index={@score_animation_card_index}
        />
      </div>
      
    <!-- Bottom - Player Cards -->
      <div class="flex-1 flex flex-col justify-start p-4 bg-base-200/40">
        <.player_cards
          player_state={@player_state}
          selected_card_ids={@selected_card_ids}
          your_card_sort={@your_card_sort}
          new_card_ids={@new_card_ids}
          player_face_down_card_ids={@player_face_down_card_ids}
          action_in_progress={@action_in_progress}
        />
      </div>
      
    <!-- Action Bar -->
      <.action_bar
        player_state={@player_state}
        opponent_state={@opponent_state}
        selected_card_ids={@selected_card_ids}
        action_in_progress={@action_in_progress}
        viewing_results={@viewing_results}
        console_open={@console_open}
        console_tab={@console_tab}
        viewing_own_deck={@viewing_own_deck}
        levels_view_mode={@levels_view_mode}
        player_name={@player_name}
        opponent_name={@opponent_name}
        player_id={@player_id}
        event_log={@event_log}
        game_state={@game_state}
      />
    </div>
    """
  end

  def opponent_cards(assigns) do
    # Default face_down_card_ids to empty list if not provided
    assigns = assign_new(assigns, :opponent_face_down_card_ids, fn -> [] end)

    ~H"""
    <!-- Card controls for opponent -->
    <div class="flex justify-center gap-2 mb-2">
      <button
        phx-click="toggle_opponent_card_sort"
        class="px-3 py-1 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 w-32 justify-center"
      >
        <span class="text-gray-500">Sorting by</span>
        <span class="font-semibold text-gray-800">
          {if @opponent_card_sort == :rank, do: "Rank", else: "Suit"}
        </span>
      </button>
    </div>
    <div class="flex flex-wrap gap-4 justify-center mb-2">
      <%= for card <- sort_cards(@opponent_state.card_piles.hand_pile, @opponent_card_sort) do %>
        <% is_new = card.id in @opponent_new_card_ids %>
        <% is_face_down = card.id in @opponent_face_down_card_ids %>
        <.card_display
          card={card}
          class={["w-28 h-40", if(is_new, do: "new-card", else: "")]}
          face_down={is_face_down}
        />
      <% end %>
    </div>
    """
  end

  def player_cards(assigns) do
    # Default face_down_card_ids to empty list if not provided
    assigns = assign_new(assigns, :player_face_down_card_ids, fn -> [] end)

    ~H"""
    <% # Compute selected card IDs based on locked_in_hand or local state
    selected_card_ids =
      if @player_state.locked_in_hand != nil do
        Enum.map(@player_state.locked_in_hand, fn card -> card.id end)
      else
        @selected_card_ids
      end

    is_locked_in = @player_state.locked_in_hand != nil %>

    <div class="flex flex-wrap gap-4 justify-center mb-2">
      <%= for card <- sort_cards(@player_state.card_piles.hand_pile, @your_card_sort) do %>
        <% selected = card.id in selected_card_ids %>
        <% at_limit = length(selected_card_ids) >= 5 %>
        <% is_new = card.id in @new_card_ids %>
        <% is_face_down = card.id in @player_face_down_card_ids %>
        <button
          phx-click="toggle_card"
          phx-value-id={card.id}
          disabled={@action_in_progress || (at_limit && not selected) || is_locked_in}
          class={[
            "transition-all",
            if(selected, do: "-translate-y-4", else: ""),
            if((at_limit && not selected) || is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <.card_display
            card={card}
            class={["w-28 h-40", if(is_new, do: "new-card", else: "")]}
            face_down={is_face_down}
          />
        </button>
      <% end %>
    </div>
    <!-- Card controls for player -->
    <div class="flex justify-center gap-2 mt-2">
      <button
        phx-click="toggle_your_card_sort"
        class="px-3 py-1 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 w-32 justify-center"
      >
        <span class="text-gray-500">Sorting by</span>
        <span class="font-semibold text-gray-800">
          {if @your_card_sort == :rank, do: "Rank", else: "Suit"}
        </span>
      </button>
    </div>
    """
  end

  def player_stats(assigns) do
    ~H"""
    <div class="flex flex-col items-center gap-2">
      <div class="flex items-center gap-4 text-base-content text-lg">
        <div class="flex items-center gap-1">
          <.icon name="hero-heart" class="w-5 h-5" />
          <span>{@player_state.lives}</span>
        </div>
        <div class="flex items-center gap-1">
          <.icon name="hero-trash" class="w-5 h-5" />
          <span>{@player_state.discards_remaining}</span>
        </div>
      </div>

      <%= if @player_state.active_debuffs != [] do %>
        <div class="flex items-center gap-2 px-3 py-1 bg-player rounded-lg">
          <.icon name="hero-hand-thumb-down-solid" class="w-4 h-4 text-sky-900" />
          <span class="text-xs font-semibold text-sky-900">Blocked:</span>
          <div class="flex gap-1">
            <%= for hand_type <- @player_state.active_debuffs do %>
              <span class="text-xs px-2 py-0.5 bg-sky-800/20 rounded text-sky-900 font-medium">
                {format_hand_name_short(hand_type)}
              </span>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if @player_state.scrambled do %>
        <div class="flex items-center gap-2 px-3 py-1 bg-player rounded-lg">
          <.icon name="hero-hand-thumb-down-solid" class="w-4 h-4 text-sky-900" />
          <span class="text-xs font-semibold text-sky-900">Scrambled</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_hand_name_short(:high_card), do: "High"
  defp format_hand_name_short(:pair), do: "Pair"
  defp format_hand_name_short(:two_pair), do: "2 Pair"
  defp format_hand_name_short(:three_of_a_kind), do: "3 Kind"
  defp format_hand_name_short(:straight), do: "Straight"
  defp format_hand_name_short(:flush), do: "Flush"
  defp format_hand_name_short(:full_house), do: "Full"
  defp format_hand_name_short(:four_of_a_kind), do: "4 Kind"
  defp format_hand_name_short(:straight_flush), do: "Str Flush"

  def action_bar(assigns) do
    ~H"""
    <% # Compute selected card IDs and lock status
    selected_card_ids =
      if @player_state.locked_in_hand != nil do
        Enum.map(@player_state.locked_in_hand, fn card -> card.id end)
      else
        @selected_card_ids
      end

    is_locked_in = @player_state.locked_in_hand != nil %>

    <div class="h-20 bg-base-200/40 flex items-center justify-between px-8 border-t border-base-content/15">
      <!-- Left: Console Button + Panel -->
      <div class="relative">
        <button
          phx-click="toggle_console"
          class={[
            "px-5 py-2 rounded-lg transition-all font-medium",
            if(@console_open,
              do: "bg-neutral text-neutral-content shadow-md",
              else: "bg-neutral/80 hover:bg-neutral text-neutral-content shadow-sm"
            )
          ]}
        >
          Console
        </button>

        <%= if @console_open do %>
          <.console_panel
            console_tab={@console_tab}
            viewing_own_deck={@viewing_own_deck}
            levels_view_mode={@levels_view_mode}
            player_state={@player_state}
            opponent_state={@opponent_state}
            player_name={@player_name}
            opponent_name={@opponent_name}
            player_id={@player_id}
            event_log={@event_log}
            game_state={@game_state}
          />
        <% end %>
      </div>
      
    <!-- Right: Action Buttons (always visible, disabled during results) -->
      <div class="flex items-center gap-4">
        <button
          phx-click="discard_cards"
          disabled={
            @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
              @player_state.discards_remaining == 0 || is_locked_in
          }
          class={[
            "px-4 py-2 rounded transition-colors bg-error hover:bg-error/90 text-error-content",
            if(
              @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
                @player_state.discards_remaining == 0 || is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <%= if @action_in_progress do %>
            Discarding...
          <% else %>
            Discard
          <% end %>
        </button>

        <button
          phx-click="lock_in_hand"
          disabled={
            @viewing_results || @action_in_progress || length(selected_card_ids) == 0 || is_locked_in
          }
          class={[
            "px-4 py-2 rounded transition-colors bg-primary hover:bg-primary/90 text-primary-content",
            if(
              @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
                is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <%= if @action_in_progress do %>
            Playing...
          <% else %>
            Play
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  def console_panel(assigns) do
    ~H"""
    <div class="absolute bottom-full left-0 mb-2 w-[730px] max-h-[70vh] bg-base-100 rounded-lg shadow-xl border border-base-300 flex flex-col">
      <!-- Tab bar -->
      <div class="flex border-b border-base-300">
        <button
          phx-click="set_console_tab"
          phx-value-tab="decks"
          class={[
            "flex-1 px-4 py-2 text-sm font-medium transition-colors",
            if(@console_tab == :decks,
              do: "bg-base-200 text-base-content border-b-2 border-primary",
              else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
            )
          ]}
        >
          Decks
        </button>
        <button
          phx-click="set_console_tab"
          phx-value-tab="levels"
          class={[
            "flex-1 px-4 py-2 text-sm font-medium transition-colors",
            if(@console_tab == :levels,
              do: "bg-base-200 text-base-content border-b-2 border-primary",
              else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
            )
          ]}
        >
          Levels
        </button>
        <button
          phx-click="set_console_tab"
          phx-value-tab="log"
          class={[
            "flex-1 px-4 py-2 text-sm font-medium transition-colors",
            if(@console_tab == :log,
              do: "bg-base-200 text-base-content border-b-2 border-primary",
              else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
            )
          ]}
        >
          Log
        </button>
      </div>
      
    <!-- Tab content -->
      <div class="overflow-y-auto p-4">
        <%= case @console_tab do %>
          <% :log -> %>
            <.console_log_tab
              event_log={@event_log}
              player_names={@game_state.player_names}
              player_id={@player_id}
            />
          <% :decks -> %>
            <.console_decks_tab
              viewing_own_deck={@viewing_own_deck}
              player_state={@player_state}
              opponent_state={@opponent_state}
              player_name={@player_name}
              opponent_name={@opponent_name}
            />
          <% :levels -> %>
            <.console_levels_tab
              levels_view_mode={@levels_view_mode}
              player_state={@player_state}
              opponent_state={@opponent_state}
              player_name={@player_name}
              opponent_name={@opponent_name}
            />
        <% end %>
      </div>
    </div>
    """
  end

  defp console_log_tab(assigns) do
    alias Oskol.Game.EventLog

    ~H"""
    <div class="space-y-2">
      <%= for event <- EventLog.get_all(@event_log) |> Enum.take(50) do %>
        <div class="text-xs bg-base-200 rounded p-2 border-l-2 border-base-content/30">
          <span class="font-medium text-base-content/50">#{event.sequence}</span>
          <span class="ml-2">{format_event_type(event.type)}</span>
        </div>
      <% end %>
      <%= if EventLog.count(@event_log) == 0 do %>
        <div class="text-sm text-base-content/50 text-center py-4">No events yet</div>
      <% end %>
    </div>
    """
  end

  defp format_event_type(type) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp console_decks_tab(assigns) do
    ~H"""
    <% current_state = @player_state
    draw_pile = current_state.card_piles.draw_pile
    hand_pile = current_state.card_piles.hand_pile
    hand_ids = MapSet.new(Enum.map(hand_pile, & &1.id))
    face_down_ids = MapSet.new(current_state.face_down_card_ids)
    all_cards = draw_pile ++ hand_pile

    cards_remaining = length(all_cards)
    face_down_count = Enum.count(hand_pile, fn card -> card.id in face_down_ids end) %>

    <div class="text-xs text-base-content/70 mb-3">
      {cards_remaining} cards left
      <%= if face_down_count > 0 do %>
        <span class="text-player/70">
          ({face_down_count} face-down {if face_down_count == 1, do: "card", else: "cards"} in hand not highlighted)
        </span>
      <% end %>
    </div>

    <% suits = [:spades, :hearts, :clubs, :diamonds]
    ranks = [14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2] %>

    <!-- Cards in fixed 13-column grid per suit, duplicates in extra rows -->
    <div class="space-y-3">
      <%= for suit <- suits do %>
        <% # Get all cards of this suit, group by rank
        suit_cards = Enum.filter(all_cards, fn card -> card.suit == suit end)
        cards_by_rank = Enum.group_by(suit_cards, fn card -> card.rank end)

        max_dupes =
          if map_size(cards_by_rank) > 0 do
            cards_by_rank |> Map.values() |> Enum.map(&length/1) |> Enum.max()
          else
            1
          end %>
        <div class="flex items-start gap-2">
          <!-- Suit count -->
          <div class="w-4 text-center pt-1 text-xs text-base-content/50">
            {length(suit_cards)}
          </div>
          <!-- Fixed 13-column grid with extra rows for duplicates -->
          <div class="flex-1 space-y-1">
            <%= for row_idx <- 0..(max_dupes - 1) do %>
              <div class="flex gap-1">
                <%= for rank <- ranks do %>
                  <% cards_at_rank = Map.get(cards_by_rank, rank, [])
                  card = Enum.at(cards_at_rank, row_idx) %>
                  <%= if card do %>
                    <% in_hand = card.id in hand_ids
                    is_face_down = card.id in face_down_ids
                    # Face-down cards in hand should not be highlighted (treated like draw pile)
                    opacity = if in_hand and not is_face_down, do: "opacity-100", else: "opacity-40" %>
                    <.card_display card={card} class={"w-12 h-[72px] #{opacity}"} compact={true} />
                  <% else %>
                    <div class="w-12 h-[72px] bg-base-300/20 rounded"></div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp console_levels_tab(assigns) do
    ~H"""
    <% current_state = @player_state

    hand_types = [
      :high_card,
      :pair,
      :two_pair,
      :three_of_a_kind,
      :straight,
      :flush,
      :full_house,
      :four_of_a_kind,
      :straight_flush
    ]

    hand_names = %{
      high_card: "High Card",
      pair: "Pair",
      two_pair: "Two Pair",
      three_of_a_kind: "3 of a Kind",
      straight: "Straight",
      flush: "Flush",
      full_house: "Full House",
      four_of_a_kind: "4 of a Kind",
      straight_flush: "Straight Flush"
    } %>

    <div class="space-y-1">
      <%= for hand_type <- hand_types do %>
        <% level = Map.get(current_state.skill_tree, hand_type, 1)
        stats = Oskol.Poker.Score.stats_at_level(hand_type, level) %>
        <div class="flex items-center justify-between py-1 px-2 rounded hover:bg-base-200">
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/50 w-6">Lv{level}</span>
            <span class="text-sm">{hand_names[hand_type]}</span>
          </div>
          <span class="text-xs text-base-content/70">
            {stats.base_chips} × {stats.multiplier}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  def playing_area(assigns) do
    # Get connection status for each player
    player_connected =
      Map.get(assigns.connections, assigns.player_id, %{}) |> Map.get(:connected, false)

    opponent_connected =
      Map.get(assigns.connections, assigns.opponent_id, %{}) |> Map.get(:connected, false)

    assigns =
      assigns
      |> assign(:player_connected, player_connected)
      |> assign(:opponent_connected, opponent_connected)

    ~H"""
    <div class="h-full relative">
      <!-- Round info - top left -->
      <div class="absolute top-4 left-4 text-left text-base-content">
        <div class="text-lg">Round {@game_state.round_number}</div>
        <div class="text-sm text-base-content/70">
          <%= cond do %>
            <% @player_state.hands_remaining == 0 -> %>
              Round complete
            <% @player_state.hands_remaining == 1 -> %>
              Final hand
            <% true -> %>
              {@player_state.hands_remaining} hands remaining
          <% end %>
        </div>
        <% player_score = @player_state.current_round_score
        opponent_score = @opponent_state.current_round_score
        score_diff = abs(player_score - opponent_score)
        round_complete = @player_state.hands_remaining == 0
        animation_in_progress = @viewing_results && @score_animation_phase not in [:idle, :complete] %>
        <%= cond do %>
          <% animation_in_progress -> %>
            <div class="text-sm text-base-content/50 mt-1 animate-pulse">
              Calculating...
            </div>
          <% score_diff > 0 -> %>
            <div class="text-sm text-base-content/70 mt-1">
              <%= if player_score > opponent_score do %>
                <span class="text-player">{@player_name}</span>
                <span>
                  <%= if round_complete do %>
                    wins by {score_diff} {if score_diff == 1, do: "point", else: "points"}
                  <% else %>
                    is ahead by {score_diff} {if score_diff == 1, do: "point", else: "points"}
                  <% end %>
                </span>
              <% else %>
                <span class="text-opponent">{@opponent_name}</span>
                <span>
                  <%= if round_complete do %>
                    wins by {score_diff} {if score_diff == 1, do: "point", else: "points"}
                  <% else %>
                    is ahead by {score_diff} {if score_diff == 1, do: "point", else: "points"}
                  <% end %>
                </span>
              <% end %>
            </div>
          <% true -> %>
        <% end %>
        
    <!-- Active effects display -->
        <!-- Effects on YOU (bad - thumbs down, player color) -->
        <%= if @player_state.active_debuffs != [] do %>
          <div class="flex items-center gap-1 mt-2 px-2 py-1 bg-player rounded">
            <.icon name="hero-hand-thumb-down-solid" class="w-3 h-3 text-sky-900" />
            <span class="text-xs font-semibold text-sky-900">
              {Enum.map(@player_state.active_debuffs, &format_hand_name_short/1) |> Enum.join(", ")} blocked
            </span>
          </div>
        <% end %>

        <%= if @player_state.scrambled do %>
          <div class="group relative flex items-center gap-1 mt-1 px-2 py-1 bg-player rounded cursor-default">
            <.icon name="hero-hand-thumb-down-solid" class="w-3 h-3 text-sky-900" />
            <span class="text-xs font-semibold text-sky-900">Scrambled</span>
            <div class="absolute top-1/2 -translate-y-1/2 left-full ml-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
              1-in-4 drawn cards are face-down
            </div>
          </div>
        <% end %>
        
    <!-- Effects on OPPONENT (good for you - thumbs up, opponent color) -->
        <%= if @opponent_state.active_debuffs != [] do %>
          <div class="flex items-center gap-1 mt-1 px-2 py-1 bg-opponent rounded">
            <.icon name="hero-hand-thumb-up-solid" class="w-3 h-3 text-orange-900" />
            <span class="text-xs font-semibold text-orange-900">
              {Enum.map(@opponent_state.active_debuffs, &format_hand_name_short/1) |> Enum.join(", ")} blocked
            </span>
          </div>
        <% end %>

        <%= if @opponent_state.scrambled do %>
          <div class="group relative flex items-center gap-1 mt-1 px-2 py-1 bg-opponent rounded cursor-default">
            <.icon name="hero-hand-thumb-up-solid" class="w-3 h-3 text-orange-900" />
            <span class="text-xs font-semibold text-orange-900">Scrambled</span>
            <div class="absolute top-1/2 -translate-y-1/2 left-full ml-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
              1-in-4 drawn cards are face-down
            </div>
          </div>
        <% end %>
      </div>
      
    <!-- Opponent status - top right -->
      <div class="absolute top-4 right-4 flex flex-col items-end gap-0.5 text-base-content">
        <div class="flex items-center gap-1">
          <span class={"w-2 h-2 rounded-full #{if @opponent_connected, do: "bg-green-500", else: "bg-gray-500"}"}>
          </span>
          <span class="text-sm text-opponent">{@opponent_name}</span>
        </div>
        <div class="group relative flex items-center gap-0.5 cursor-default">
          <%= for i <- 1..@game_state.initial_lives do %>
            <%= if i > @game_state.initial_lives - @opponent_state.lives do %>
              <.icon name="hero-heart-solid" class="w-4 h-4 text-base-content/70" />
            <% else %>
              <.icon name="hero-heart" class="w-4 h-4 text-base-content/30" />
            <% end %>
          <% end %>
          <div class="absolute top-1/2 -translate-y-1/2 right-full mr-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
            {@opponent_state.lives} {if @opponent_state.lives == 1, do: "life", else: "lives"} left
          </div>
        </div>
        <div class="group relative flex items-center gap-0.5 cursor-default">
          <%= for i <- 1..@game_state.discards_per_round do %>
            <%= if i > @game_state.discards_per_round - @opponent_state.discards_remaining do %>
              <.icon name="hero-trash-solid" class="w-4 h-4 text-base-content/70" />
            <% else %>
              <.icon name="hero-trash" class="w-4 h-4 text-base-content/30" />
            <% end %>
          <% end %>
          <div class="absolute top-1/2 -translate-y-1/2 right-full mr-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
            {@opponent_state.discards_remaining} {if @opponent_state.discards_remaining == 1,
              do: "discard",
              else: "discards"} left
          </div>
        </div>
      </div>
      
    <!-- Player status - bottom right -->
      <div class="absolute bottom-4 right-4 flex flex-col items-end gap-0.5 text-base-content">
        <div class="group relative flex items-center gap-0.5 cursor-default">
          <%= for i <- 1..@game_state.discards_per_round do %>
            <%= if i > @game_state.discards_per_round - @player_state.discards_remaining do %>
              <.icon name="hero-trash-solid" class="w-4 h-4 text-base-content/70" />
            <% else %>
              <.icon name="hero-trash" class="w-4 h-4 text-base-content/30" />
            <% end %>
          <% end %>
          <div class="absolute top-1/2 -translate-y-1/2 right-full mr-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
            {@player_state.discards_remaining} {if @player_state.discards_remaining == 1,
              do: "discard",
              else: "discards"} left
          </div>
        </div>
        <div class="group relative flex items-center gap-0.5 cursor-default">
          <%= for i <- 1..@game_state.initial_lives do %>
            <%= if i > @game_state.initial_lives - @player_state.lives do %>
              <.icon name="hero-heart-solid" class="w-4 h-4 text-base-content/70" />
            <% else %>
              <.icon name="hero-heart" class="w-4 h-4 text-base-content/30" />
            <% end %>
          <% end %>
          <div class="absolute top-1/2 -translate-y-1/2 right-full mr-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
            {@player_state.lives} {if @player_state.lives == 1, do: "life", else: "lives"} left
          </div>
        </div>
        <div class="flex items-center gap-1">
          <span class={"w-2 h-2 rounded-full #{if @player_connected, do: "bg-green-500", else: "bg-gray-500"}"}>
          </span>
          <span class="text-sm text-player">{@player_name}</span>
        </div>
      </div>
      
    <!-- Centered content -->
      <div class="h-full flex flex-col justify-center">
        <%= cond do %>
          <% @viewing_results && @game_state.last_hand_results != nil -> %>
            <.animated_score_display
              game_state={@game_state}
              player_id={@player_id}
              opponent_id={@opponent_id}
              player_name={@player_name}
              opponent_name={@opponent_name}
              animation_phase={@score_animation_phase}
              animation_card_index={@score_animation_card_index}
            />
          <% @player_state.locked_in_hand != nil && @opponent_state.locked_in_hand == nil -> %>
            <.waiting_for_opponent player_name={@player_name} hand={@player_state.locked_in_hand} />
          <% @opponent_state.locked_in_hand != nil && @player_state.locked_in_hand == nil -> %>
            <.opponent_locked_notice />
          <% true -> %>
            <!-- Round info shown in top left, nothing else to display -->
            <div></div>
        <% end %>
      </div>
    </div>
    """
  end

  def hand_results_display(assigns) do
    ~H"""
    <div class="text-center space-y-16">
      <% opponent_result = @game_state.last_hand_results[@opponent_id] %>
      <.locked_hand_display
        player_name={@opponent_name}
        hand={opponent_result.hand}
        hand_type={opponent_result.hand_type}
        score={opponent_result.score}
        color="text-opponent"
        show_result={true}
        is_current_player={false}
      />

      <% my_result = @game_state.last_hand_results[@player_id] %>
      <.locked_hand_display
        player_name={@player_name}
        hand={my_result.hand}
        hand_type={my_result.hand_type}
        score={my_result.score}
        color="text-player"
        show_result={true}
        is_current_player={true}
      />
    </div>
    """
  end

  @doc """
  Animated score breakdown display showing Balatro-style formula with cards highlighted sequentially.
  Layout: opponent on top, player on bottom (so your cards are near you).
  Animation order is alphabetical by player name so both players see the same reveal timing.
  """
  def animated_score_display(assigns) do
    opponent_result = assigns.game_state.last_hand_results[assigns.opponent_id]
    player_result = assigns.game_state.last_hand_results[assigns.player_id]

    # Determine animation order alphabetically - both players see same timing
    # "first" animates during opponent_* phases, "second" during player_* phases
    player_is_first = assigns.player_name <= assigns.opponent_name

    # Get animation states based on alphabetical order
    {_opponent_visible, opponent_state} =
      get_player_animation_state(
        assigns.animation_phase,
        assigns.animation_card_index,
        if(player_is_first, do: :player, else: :opponent),
        opponent_result
      )

    {_player_visible, player_state} =
      get_player_animation_state(
        assigns.animation_phase,
        assigns.animation_card_index,
        if(player_is_first, do: :opponent, else: :player),
        player_result
      )

    assigns =
      assigns
      |> assign(:opponent_result, opponent_result)
      |> assign(:player_result, player_result)
      |> assign(:opponent_state, opponent_state)
      |> assign(:player_state, player_state)

    ~H"""
    <div class="text-center space-y-8">
      <!-- Opponent's breakdown (always on top) -->
      <.score_breakdown_row
        result={@opponent_result}
        player_name={@opponent_name}
        animation_state={@opponent_state || %{phase: :base, cards_scored: 0}}
        is_opponent={true}
        skill_tree={@game_state.players[@opponent_id].skill_tree}
      />
      
    <!-- Player's breakdown (always on bottom, near your cards) -->
      <.score_breakdown_row
        result={@player_result}
        player_name={@player_name}
        animation_state={@player_state || %{phase: :base, cards_scored: 0}}
        is_opponent={false}
        skill_tree={@game_state.players[@player_id].skill_tree}
      />
    </div>
    """
  end

  defp get_player_animation_state(phase, card_index, player_type, result) do
    opponent_phases = [:opponent_base, :opponent_cards, :opponent_final]
    player_phases = [:player_base, :player_cards, :player_final]

    cond do
      phase == :idle ->
        {false, nil}

      phase == :complete ->
        {true, %{phase: :final, cards_scored: length(result.score_breakdown.card_breakdowns)}}

      player_type == :opponent && phase in opponent_phases ->
        cards_scored =
          case phase do
            :opponent_base -> 0
            :opponent_cards -> card_index + 1
            :opponent_final -> length(result.score_breakdown.card_breakdowns)
          end

        {true, %{phase: phase_type(phase), cards_scored: cards_scored, current_card: card_index}}

      player_type == :opponent && phase in player_phases ->
        # Opponent is done, show final state
        {true, %{phase: :final, cards_scored: length(result.score_breakdown.card_breakdowns)}}

      player_type == :player && phase in player_phases ->
        cards_scored =
          case phase do
            :player_base -> 0
            :player_cards -> card_index + 1
            :player_final -> length(result.score_breakdown.card_breakdowns)
          end

        {true, %{phase: phase_type(phase), cards_scored: cards_scored, current_card: card_index}}

      player_type == :player && phase in opponent_phases ->
        # Player not shown yet during opponent phases
        {false, nil}

      true ->
        {false, nil}
    end
  end

  defp phase_type(:opponent_base), do: :base
  defp phase_type(:opponent_cards), do: :cards
  defp phase_type(:opponent_final), do: :final
  defp phase_type(:player_base), do: :base
  defp phase_type(:player_cards), do: :cards
  defp phase_type(:player_final), do: :final
  defp phase_type(_), do: :final

  defp score_breakdown_row(assigns) do
    breakdown = assigns.result.score_breakdown
    # Sort hand by rank for easier reading
    hand = sort_cards(assigns.result.hand, :rank)
    # Sort card_breakdowns by rank too so animation goes left to right
    sorted_breakdowns =
      Enum.sort_by(breakdown.card_breakdowns, fn b -> {-b.card.rank, suit_order(b.card.suit)} end)

    breakdown = %{breakdown | card_breakdowns: sorted_breakdowns}
    scoring_card_ids = MapSet.new(Enum.map(breakdown.card_breakdowns, & &1.card.id))

    # Calculate running totals based on cards scored
    cards_scored = assigns.animation_state.cards_scored

    {running_chips, running_mult} =
      if cards_scored == 0 do
        {breakdown.base_chips, breakdown.base_multiplier}
      else
        scored_breakdowns = Enum.take(breakdown.card_breakdowns, cards_scored)

        extra_chips =
          scored_breakdowns
          |> Enum.map(fn b -> b.chip_value + b.bonus_chips end)
          |> Enum.sum()

        extra_mult =
          scored_breakdowns
          |> Enum.map(fn b -> b.bonus_mult end)
          |> Enum.sum()

        {breakdown.base_chips + extra_chips, breakdown.base_multiplier + extra_mult}
      end

    show_final = assigns.animation_state.phase == :final
    running_score = running_chips * running_mult

    level = Map.get(assigns.skill_tree, breakdown.hand_type, 1)

    hand_type_text =
      "Lvl #{level} " <>
        (breakdown.hand_type
         |> Atom.to_string()
         |> String.replace("_", " ")
         |> String.upcase())

    assigns =
      assigns
      |> assign(:breakdown, breakdown)
      |> assign(:hand, hand)
      |> assign(:scoring_card_ids, scoring_card_ids)
      |> assign(:running_chips, running_chips)
      |> assign(:running_mult, running_mult)
      |> assign(:running_score, running_score)
      |> assign(:show_final, show_final)
      |> assign(:hand_type_text, hand_type_text)
      |> assign(:cards_scored, cards_scored)

    ~H"""
    <div class={if @is_opponent, do: "", else: ""}>
      <!-- Hand type header -->
      <div class="text-sm text-base-content/80 mb-2">
        {@hand_type_text}
      </div>
      
    <!-- Cards display -->
      <div class="flex gap-2 justify-center mb-3">
        <%= for card <- @hand do %>
          <% is_scoring = card.id in @scoring_card_ids

          scoring_index =
            if is_scoring,
              do: Enum.find_index(@breakdown.card_breakdowns, fn b -> b.card.id == card.id end),
              else: nil

          is_currently_scoring =
            scoring_index != nil && scoring_index == @cards_scored - 1 &&
              @animation_state.phase == :cards

          card_class =
            cond do
              not is_scoring -> "card-not-scoring"
              scoring_index != nil && scoring_index < @cards_scored - 1 -> "card-scored"
              is_currently_scoring -> "card-scoring"
              scoring_index != nil && scoring_index < @cards_scored -> "card-scored"
              true -> ""
            end

          # Get card breakdown for floating indicator
          card_breakdown =
            if is_currently_scoring && scoring_index != nil do
              Enum.at(@breakdown.card_breakdowns, scoring_index)
            end %>
          <div class="relative">
            <.card_display card={card} class={"w-16 h-24 #{card_class}"} />
            <%= if card_breakdown do %>
              <div class="chip-float chip-float-chips">
                +{card_breakdown.chip_value + card_breakdown.bonus_chips}
              </div>
              <%= if card_breakdown.bonus_mult > 0 do %>
                <div class="chip-float chip-float-mult" style="top: 8px;">
                  +{card_breakdown.bonus_mult}x
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Formula display -->
      <div class="flex items-center justify-center gap-3 text-lg font-mono">
        <span class="text-blue-400 font-bold">{@running_chips}</span>
        <span class="text-base-content/60">×</span>
        <span class="text-red-400 font-bold">{@running_mult}</span>
        <%= if @show_final do %>
          <span class="text-base-content/60">=</span>
          <span class="text-yellow-400 font-bold text-xl score-reveal">{@running_score}</span>
        <% end %>
      </div>
    </div>
    """
  end

  def waiting_for_opponent(assigns) do
    # Sort hand by rank for consistent display
    sorted_hand = sort_cards(assigns.hand, :rank)
    assigns = assign(assigns, :sorted_hand, sorted_hand)

    ~H"""
    <div class="text-center space-y-8">
      <!-- Opponent placeholder - same height as score breakdown row -->
      <div>
        <div class="text-sm text-base-content/50 mb-2">Waiting for opponent...</div>
        <div class="flex gap-2 justify-center mb-3">
          <!-- Invisible placeholder cards to reserve space -->
          <%= for _i <- 1..length(@sorted_hand) do %>
            <div class="w-16 h-24 opacity-0"></div>
          <% end %>
        </div>
        <div class="h-7"></div>
        <!-- placeholder for formula row -->
      </div>
      
    <!-- Player's locked hand -->
      <div>
        <div class="text-sm text-base-content/80 mb-2">&nbsp;</div>
        <div class="flex gap-2 justify-center mb-3">
          <%= for card <- @sorted_hand do %>
            <.card_display card={card} class="w-16 h-24" />
          <% end %>
        </div>
        <div class="h-7"></div>
        <!-- placeholder for formula row -->
      </div>
    </div>
    """
  end

  def opponent_locked_notice(assigns) do
    ~H"""
    <div class="text-center text-base-content/50 text-sm">
      Opponent has locked in their hand
    </div>
    """
  end

  def round_info_display(assigns) do
    ~H"""
    <div class="text-base-content text-lg">
      Round {@game_state.round_number} - Beat your opponent to survive
    </div>
    """
  end

  def locked_hand_display(assigns) do
    # Sort hand by rank for consistent display
    sorted_hand = sort_cards(assigns.hand, :rank)
    assigns = assign(assigns, :sorted_hand, sorted_hand)

    ~H"""
    <div>
      <%= if @show_result do %>
        <% hand_type_text =
          @hand_type |> Atom.to_string() |> String.replace("_", " ") |> String.upcase() %>
        <%= if not @is_current_player do %>
          <div class="flex items-center justify-center gap-2 text-sm text-base-content/80 mb-2">
            <span>{String.capitalize(@player_name)}</span>
            <span class="text-base-content/40">|</span>
            <span>{hand_type_text}</span>
            <span class="text-base-content/40">|</span>
            <.icon name="hero-star" class="w-4 h-4" />
            <span>{@score}</span>
          </div>
        <% end %>
      <% end %>

      <div class="flex gap-2 justify-center mb-2">
        <%= for card <- @sorted_hand do %>
          <.card_display card={card} class="w-20 h-28" />
        <% end %>
      </div>

      <%= if @show_result do %>
        <% hand_type_text =
          @hand_type |> Atom.to_string() |> String.replace("_", " ") |> String.upcase() %>
        <%= if @is_current_player do %>
          <div class="flex items-center justify-center gap-2 text-sm text-base-content/80">
            <span>{hand_type_text}</span>
            <span class="text-base-content/40">|</span>
            <.icon name="hero-star" class="w-4 h-4" />
            <span>{@score}</span>
          </div>
        <% end %>
      <% else %>
        <div class="text-xs text-base-content/50">Locked In</div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  @doc """
  Reusable card display component with enhancement badge support.

  ## Options
  - card: The card struct to display
  - class: Additional CSS classes for the container
  - show_enhancement: Whether to show the enhancement badge (default: true)
  - compact: Use smaller enhancement badge for small card displays (default: false)
  """
  def card_display(assigns) do
    # Set defaults
    assigns =
      assigns
      |> assign_new(:class, fn -> "" end)
      |> assign_new(:show_enhancement, fn -> true end)
      |> assign_new(:compact, fn -> false end)
      |> assign_new(:face_down, fn -> false end)

    enhancement_text =
      if assigns.show_enhancement and not assigns.face_down do
        case assigns.card.enhancement do
          {:bonus_chips, amount} -> "+#{amount}c"
          {:bonus_mult, amount} -> "+#{amount}x"
          nil -> nil
        end
      else
        nil
      end

    card_url =
      if assigns.face_down do
        "/images/cards/1B.svg"
      else
        card_to_png_url(assigns.card)
      end

    assigns =
      assigns
      |> assign(:enhancement_text, enhancement_text)
      |> assign(:card_url, card_url)

    ~H"""
    <div class={"rounded overflow-hidden relative #{@class}"}>
      <img src={@card_url} class="w-full h-full" />
      <%= if @enhancement_text do %>
        <div class={[
          "absolute bg-purple-600 text-white font-bold rounded shadow-lg",
          if(@compact,
            do: "top-px right-px text-[8px] px-0.5 py-0",
            else: "top-0.5 right-0.5 text-xs px-1.5 py-0.5"
          )
        ]}>
          {@enhancement_text}
        </div>
      <% end %>
    </div>
    """
  end

  def card_to_png_url(%Card{rank: rank, suit: suit}) do
    rank_str =
      case rank do
        14 -> "A"
        13 -> "K"
        12 -> "Q"
        11 -> "J"
        10 -> "T"
        n -> Integer.to_string(n)
      end

    suit_str =
      case suit do
        :hearts -> "H"
        :diamonds -> "D"
        :clubs -> "C"
        :spades -> "S"
      end

    "/images/cards/#{rank_str}#{suit_str}.svg"
  end

  defp sort_cards(cards, :rank) do
    Enum.sort_by(cards, fn card -> {-card.rank, suit_order(card.suit)} end)
  end

  defp sort_cards(cards, :suit) do
    Enum.sort_by(cards, fn card -> {suit_order(card.suit), -card.rank} end)
  end

  defp suit_order(:spades), do: 0
  defp suit_order(:hearts), do: 1
  defp suit_order(:clubs), do: 2
  defp suit_order(:diamonds), do: 3

  def deck_modal(assigns) do
    ~H"""
    <%= if @viewing_deck do %>
      <div
        class="fixed inset-0 backdrop-blur-sm bg-base-100/50 flex items-center justify-center z-50"
        phx-click="close_deck"
      >
        <div
          class="bg-base-100 rounded-lg shadow-xl p-6 max-w-6xl w-full max-h-[90vh] overflow-y-auto border border-base-300"
          phx-click="noop"
        >
          <div class="flex justify-between items-center mb-6">
            <div class="flex gap-4">
              <button
                phx-click="view_your_deck"
                class={[
                  "text-xl font-bold transition-all",
                  if(@viewing_own_deck,
                    do: "text-player",
                    else: "text-base-content/40 hover:text-base-content/60"
                  )
                ]}
              >
                {@player_name}
              </button>
              <span class="text-xl text-base-content/30">|</span>
              <button
                phx-click="view_opponent_deck"
                class={[
                  "text-xl font-bold transition-all",
                  if(!@viewing_own_deck,
                    do: "text-opponent",
                    else: "text-base-content/40 hover:text-base-content/60"
                  )
                ]}
              >
                {@opponent_name}
              </button>
            </div>

            <button
              phx-click="close_deck"
              class="text-base-content/60 hover:text-base-content text-2xl"
            >
              ×
            </button>
          </div>

          <% # Select which state to show
          current_state = if @viewing_own_deck, do: @player_state, else: @opponent_state

          # Organize cards by location
          draw_pile = current_state.card_piles.draw_pile
          hand_pile = current_state.card_piles.hand_pile
          hand_ids = MapSet.new(Enum.map(hand_pile, & &1.id))

          # Combine only draw pile and hand (exclude discarded cards)
          all_cards = draw_pile ++ hand_pile

          # Group cards by (suit, rank) to handle duplicates
          cards_by_position = Enum.group_by(all_cards, fn card -> {card.suit, card.rank} end)

          # Define suits and ranks in display order
          suits = [:spades, :hearts, :clubs, :diamonds]
          ranks = [14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2]

          # Rank display names
          rank_names = %{
            14 => "A",
            13 => "K",
            12 => "Q",
            11 => "J",
            10 => "10",
            9 => "9",
            8 => "8",
            7 => "7",
            6 => "6",
            5 => "5",
            4 => "4",
            3 => "3",
            2 => "2"
          }

          # Suit display symbols
          suit_symbols = %{
            spades: "♠",
            hearts: "♥",
            clubs: "♣",
            diamonds: "♦"
          }

          # Count cards
          total_cards =
            length(draw_pile) + length(hand_pile) + length(current_state.card_piles.discard_pile)

          cards_remaining = length(all_cards) %>

          <div class="mb-3 text-sm text-base-content/70">
            Total: {cards_remaining} / {total_cards} cards remaining
          </div>
          
    <!-- Table layout -->
          <div class="overflow-x-auto">
            <table class="border-collapse">
              <!-- Body rows with suits -->
              <tbody>
                <%= for suit <- suits do %>
                  <% # Count remaining cards of this suit (draw pile + hand, excludes discards)
                  suit_remaining = Enum.count(all_cards, fn card -> card.suit == suit end) %>
                  <tr>
                    <td class="px-2 py-1 text-left text-base font-semibold">
                      <span class="text-xs text-base-content/60 mr-1">
                        {suit_remaining}
                      </span>
                      <span class={[
                        if(suit in [:hearts, :diamonds], do: "text-error", else: "text-base-content")
                      ]}>
                        {suit_symbols[suit]}
                      </span>
                    </td>
                    <%= for rank <- ranks do %>
                      <td class="p-1">
                        <% cards_at_position = Map.get(cards_by_position, {suit, rank}, []) %>
                        <%= if length(cards_at_position) > 0 do %>
                          <% # Calculate height needed for stacked cards
                          stack_height = 96 + (length(cards_at_position) - 1) * 20 %>
                          <div class="relative" style={"height: #{stack_height}px; width: 64px;"}>
                            <%= for {card, index} <- Enum.with_index(cards_at_position) do %>
                              <% in_hand = card.id in hand_ids
                              opacity_class = if in_hand, do: "opacity-100", else: "opacity-30"
                              top_offset = index * 20 %>
                              <div class="absolute" style={"top: #{top_offset}px;"}>
                                <.card_display
                                  card={card}
                                  class={"w-16 h-24 #{opacity_class}"}
                                />
                              </div>
                            <% end %>
                          </div>
                        <% else %>
                          <div class="w-16 h-24"></div>
                        <% end %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  def levels_modal(assigns) do
    ~H"""
    <%= if @viewing_levels do %>
      <div
        class="fixed inset-0 backdrop-blur-sm bg-base-100/50 flex items-center justify-center z-50"
        phx-click="close_levels"
      >
        <div
          class="bg-base-100 rounded-lg shadow-xl p-6 max-w-3xl w-full max-h-[90vh] overflow-y-auto border border-base-300"
          phx-click="noop"
        >
          <div class="flex justify-between items-center mb-6">
            <div class="flex gap-4">
              <button
                phx-click="view_your_levels"
                class={[
                  "text-xl font-bold transition-all",
                  if(@levels_view_mode == :player,
                    do: "text-player",
                    else: "text-base-content/40 hover:text-base-content/60"
                  )
                ]}
              >
                {@player_name}
              </button>
              <span class="text-xl text-base-content/30">|</span>
              <button
                phx-click="view_opponent_levels"
                class={[
                  "text-xl font-bold transition-all",
                  if(@levels_view_mode == :opponent,
                    do: "text-opponent",
                    else: "text-base-content/40 hover:text-base-content/60"
                  )
                ]}
              >
                {@opponent_name}
              </button>
            </div>

            <button
              phx-click="close_levels"
              class="text-base-content/60 hover:text-base-content text-2xl"
            >
              ×
            </button>
          </div>

          <% # Hand types in display order
          hand_types = [
            :high_card,
            :pair,
            :two_pair,
            :three_of_a_kind,
            :straight,
            :flush,
            :full_house,
            :four_of_a_kind,
            :straight_flush
          ]

          # Hand type display names
          hand_names = %{
            high_card: "High Card",
            pair: "Pair",
            two_pair: "Two Pair",
            three_of_a_kind: "Three of a Kind",
            straight: "Straight",
            flush: "Flush",
            full_house: "Full House",
            four_of_a_kind: "Four of a Kind",
            straight_flush: "Straight Flush"
          }

          # Select the state to show based on view mode
          current_state = if @levels_view_mode == :player, do: @player_state, else: @opponent_state

          # Find max level for highlighting
          max_level =
            hand_types
            |> Enum.map(fn hand_type -> Map.get(current_state.skill_tree, hand_type, 1) end)
            |> Enum.max() %>

          <div class="max-w-3xl mx-auto">
            <table class="w-full">
              <tbody>
                <%= for hand_type <- hand_types do %>
                  <% level = Map.get(current_state.skill_tree, hand_type, 1)
                  stats = Oskol.Poker.Score.stats_at_level(hand_type, level)
                  hand_name = hand_names[hand_type]
                  is_max = level == max_level && max_level > 1 %>

                  <tr class="border-b border-base-300">
                    <td class="py-3 px-4 font-semibold text-base-content">
                      <span class="text-base-content/50 font-normal">Lv{level}</span>
                      <span class="ml-2">{hand_name}</span>
                      <%= if is_max do %>
                        <span class={[
                          "ml-1",
                          if(@levels_view_mode == :player, do: "text-player", else: "text-opponent")
                        ]}>
                          ★
                        </span>
                      <% end %>
                    </td>
                    <td class="py-3 px-4 text-sm text-right">
                      {stats.base_chips} chips × {stats.multiplier} mult
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
