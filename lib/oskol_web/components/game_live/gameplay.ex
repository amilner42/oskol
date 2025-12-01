defmodule OskolWeb.Components.GameLive.Gameplay do
  @moduledoc """
  Gameplay components including game screen, cards, and playing area.
  """
  use OskolWeb, :html

  alias Oskol.Poker.Card
  alias OskolWeb.Utils.Format

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

      @keyframes slideUp {
        from {
          transform: translateY(100%);
          opacity: 0;
        }
        to {
          transform: translateY(0);
          opacity: 1;
        }
      }

      .animate-slide-up {
        animation: slideUp 0.3s ease-out forwards;
      }

      @keyframes fadeInScale {
        from {
          opacity: 0;
          transform: scale(0.95);
        }
        to {
          opacity: 1;
          transform: scale(1);
        }
      }

      .animate-fadeInScale {
        animation: fadeInScale 0.1s ease-out forwards;
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
    <div class="flex flex-col h-screen-safe bg-base-300 overflow-hidden">
      <!-- Top - Opponent Cards: shrink on mobile, minimal padding on desktop -->
      <div class="shrink-0 flex flex-col justify-end pt-2 px-1 pb-1 sm:pt-2 sm:px-3 sm:pb-3 bg-base-200/40">
        <.opponent_cards
          opponent_state={@opponent_state}
          opponent_card_sort={@opponent_card_sort}
          opponent_new_card_ids={@opponent_new_card_ids}
          opponent_face_down_card_ids={@opponent_face_down_card_ids}
          disabled_ranks={@opponent_state.disabled_ranks}
          disabled_suits={@opponent_state.disabled_suits}
          enhancements_disabled={@opponent_state.enhancements_disabled}
        />
      </div>
      
    <!-- Middle - Playing Area: takes remaining space -->
      <div class="flex-1 min-h-0 flex flex-col justify-start bg-base-100 shadow-[0_0_30px_-5px_rgba(0,0,0,0.5)]">
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
          active_console={@active_console}
          viewing_own_deck={@viewing_own_deck}
          levels_view_mode={@levels_view_mode}
          event_log={@event_log}
        />
      </div>
      
    <!-- Bottom - Player Cards: shrink on mobile, minimal padding on desktop -->
      <div class="shrink-0 flex flex-col justify-start pt-1 px-1 pb-0 sm:pt-3 sm:px-3 sm:pb-0 bg-base-200/40">
        <.player_cards
          player_state={@player_state}
          selected_card_ids={@selected_card_ids}
          your_card_sort={@your_card_sort}
          new_card_ids={@new_card_ids}
          player_face_down_card_ids={@player_face_down_card_ids}
          action_in_progress={@action_in_progress}
          disabled_ranks={@player_state.disabled_ranks}
          disabled_suits={@player_state.disabled_suits}
          enhancements_disabled={@player_state.enhancements_disabled}
        />
      </div>

    <!-- Action Bar: fixed height -->
      <.action_bar
        player_state={@player_state}
        selected_card_ids={@selected_card_ids}
        action_in_progress={@action_in_progress}
        viewing_results={@viewing_results}
        your_card_sort={@your_card_sort}
      />

      <!-- Console Buttons (fixed at mid-left) -->
      <.console_buttons active_console={@active_console} viewing_results={@viewing_results} />
    </div>
    """
  end

  def opponent_cards(assigns) do
    # Default face_down_card_ids to empty list if not provided
    assigns =
      assigns
      |> assign_new(:opponent_face_down_card_ids, fn -> [] end)
      |> assign_new(:disabled_ranks, fn -> [] end)
      |> assign_new(:disabled_suits, fn -> [] end)
      |> assign_new(:enhancements_disabled, fn -> false end)

    ~H"""
    <!-- Card controls for opponent -->
    <div class="flex justify-center mb-2 sm:mb-3">
      <button
        phx-click="toggle_opponent_card_sort"
        class="px-3 py-1 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 touch-manipulation"
      >
        <span class="text-gray-500">Sorting by</span>
        <span class="font-semibold text-gray-800">
          {if @opponent_card_sort == :rank, do: "Rank", else: "Suit"}
        </span>
      </button>
    </div>
    <!-- Responsive card grid: flex cards that shrink on mobile, max size on desktop -->
    <div class="flex gap-1 sm:gap-3 md:gap-4 justify-center px-2 sm:px-0">
      <%= for card <- sort_cards(@opponent_state.card_piles.hand_pile, @opponent_card_sort) do %>
        <% is_new = card.id in @opponent_new_card_ids %>
        <% is_face_down = card.id in @opponent_face_down_card_ids %>
        <% is_disabled = card.rank in @disabled_ranks or card.suit in @disabled_suits %>
        <.card_display
          card={card}
          class={["flex-1 min-w-0 max-w-[112px] aspect-[5/7]", if(is_new, do: "new-card", else: "")]}
          face_down={is_face_down}
          disabled={is_disabled}
          enhancement_disabled={@enhancements_disabled}
          compact={true}
        />
      <% end %>
    </div>
    """
  end

  def player_cards(assigns) do
    # Default face_down_card_ids to empty list if not provided
    assigns =
      assigns
      |> assign_new(:player_face_down_card_ids, fn -> [] end)
      |> assign_new(:disabled_ranks, fn -> [] end)
      |> assign_new(:disabled_suits, fn -> [] end)
      |> assign_new(:enhancements_disabled, fn -> false end)

    ~H"""
    <% # Compute selected card IDs based on locked_in_hand or local state
    selected_card_ids =
      if @player_state.locked_in_hand != nil do
        Enum.map(@player_state.locked_in_hand, fn card -> card.id end)
      else
        @selected_card_ids
      end

    is_locked_in = @player_state.locked_in_hand != nil %>

    <!-- Responsive card grid: flex cards that shrink on mobile, max size on desktop -->
    <div class="flex gap-1 sm:gap-3 md:gap-4 justify-center px-2 sm:px-0">
      <%= for card <- sort_cards(@player_state.card_piles.hand_pile, @your_card_sort) do %>
        <% selected = card.id in selected_card_ids %>
        <% at_limit = length(selected_card_ids) >= 5 %>
        <% is_new = card.id in @new_card_ids %>
        <% is_face_down = card.id in @player_face_down_card_ids %>
        <% is_disabled = card.rank in @disabled_ranks or card.suit in @disabled_suits %>
        <button
          phx-click="toggle_card"
          phx-value-id={card.id}
          disabled={@action_in_progress || (at_limit && not selected) || is_locked_in}
          class={[
            "flex-1 min-w-0 max-w-[112px] transition-all touch-manipulation",
            if(selected, do: "-translate-y-2 sm:-translate-y-3 md:-translate-y-4", else: ""),
            if((at_limit && not selected) || is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <.card_display
            card={card}
            class={["w-full aspect-[5/7]", if(is_new, do: "new-card", else: "")]}
            face_down={is_face_down}
            disabled={is_disabled}
            enhancement_disabled={@enhancements_disabled}
            compact={true}
          />
        </button>
      <% end %>
    </div>
    <!-- Card controls for player - hidden on mobile (moved to action bar) -->
    <div class="hidden sm:flex justify-center mt-2 sm:mt-3">
      <button
        phx-click="toggle_your_card_sort"
        class="px-3 py-1 text-xs bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-1 touch-manipulation"
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
                {Format.hand_name(hand_type)}
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

  defp format_disabled_cards(disabled_ranks, disabled_suits) do
    rank_strs = Enum.map(disabled_ranks, &format_rank/1)
    suit_strs = Enum.map(disabled_suits, &format_suit/1)
    all_strs = rank_strs ++ suit_strs
    Enum.join(all_strs, ", ")
  end

  @doc """
  Returns a list of active sabotage badges for a player.
  Each badge is a map with: name, tooltip, and active? boolean.
  This centralizes badge logic so adding new sabotage cards is easy.
  """
  defp get_sabotage_badges(player_state) do
    [
      %{
        name: "Scrambled",
        tooltip: "1-in-5 drawn cards are face-down",
        active?: player_state.scrambled
      },
      %{
        name: "Static Field",
        tooltip: "Card enhancements disabled",
        active?: player_state.enhancements_disabled
      },
      %{
        name: "Plus Bomb",
        tooltip:
          "#{format_disabled_cards(player_state.disabled_ranks, player_state.disabled_suits)} won't score",
        active?: player_state.disabled_ranks != [] or player_state.disabled_suits != []
      },
      %{
        name: "Supply Chain",
        tooltip: "Draws limited to 4 cards per discard",
        active?: player_state.supply_chain_limited
      }
    ]
    |> Enum.filter(& &1.active?)
  end

  defp format_rank(2), do: "2s"
  defp format_rank(3), do: "3s"
  defp format_rank(4), do: "4s"
  defp format_rank(5), do: "5s"
  defp format_rank(6), do: "6s"
  defp format_rank(7), do: "7s"
  defp format_rank(8), do: "8s"
  defp format_rank(9), do: "9s"
  defp format_rank(10), do: "10s"
  defp format_rank(11), do: "Jacks"
  defp format_rank(12), do: "Queens"
  defp format_rank(13), do: "Kings"
  defp format_rank(14), do: "Aces"

  defp format_suit(:hearts), do: "Hearts"
  defp format_suit(:diamonds), do: "Diamonds"
  defp format_suit(:clubs), do: "Clubs"
  defp format_suit(:spades), do: "Spades"

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

    <!-- Action bar - Mobile: full width with 3 buttons, Desktop: right-aligned 2 buttons -->
    <div class="h-12 sm:h-20 flex items-center shrink-0">
      <!-- Mobile layout: flex row with discard left, sort center, play right -->
      <div class="sm:hidden flex items-center justify-between gap-1.5 w-full px-2">
        <!-- Discard button (left) - fixed width -->
        <button
          phx-click="discard_cards"
          disabled={
            @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
              @player_state.discards_remaining == 0 || is_locked_in
          }
          class={[
            "w-16 py-1.5 rounded transition-colors bg-error hover:bg-error/90 text-error-content shadow ring-1 ring-white/10 text-xs touch-manipulation",
            if(
              @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
                @player_state.discards_remaining == 0 || is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <%= if @action_in_progress do %>
            ...
          <% else %>
            Discard
          <% end %>
        </button>

        <!-- Sort button (center) - flexible width -->
        <button
          phx-click="toggle_your_card_sort"
          class="px-2 py-1 text-[10px] bg-white/90 hover:bg-white rounded shadow-sm transition-all flex items-center gap-0.5 touch-manipulation whitespace-nowrap"
        >
          <span class="text-gray-500">Sort:</span>
          <span class="font-semibold text-gray-800">
            {if assigns[:your_card_sort] == :rank, do: "Rank", else: "Suit"}
          </span>
        </button>

        <!-- Play button (right) - fixed width, same as discard -->
        <button
          phx-click="lock_in_hand"
          disabled={
            @viewing_results || @action_in_progress || length(selected_card_ids) == 0 || is_locked_in
          }
          class={[
            "w-16 py-1.5 rounded transition-colors bg-primary hover:bg-primary/90 text-primary-content shadow ring-1 ring-white/10 text-xs font-semibold touch-manipulation",
            if(
              @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
                is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            )
          ]}
        >
          <%= if @action_in_progress do %>
            ...
          <% else %>
            Play
          <% end %>
        </button>
      </div>

      <!-- Desktop layout: right-aligned buttons (unchanged) -->
      <div class="hidden sm:flex items-center gap-4 ml-auto px-8">
        <button
          phx-click="discard_cards"
          disabled={
            @viewing_results || @action_in_progress || length(selected_card_ids) == 0 ||
              @player_state.discards_remaining == 0 || is_locked_in
          }
          class={[
            "px-4 py-2 rounded-lg transition-colors bg-error hover:bg-error/90 text-error-content shadow-lg ring-1 ring-white/10 text-base touch-manipulation",
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
            "px-4 py-2 rounded-lg transition-colors bg-primary hover:bg-primary/90 text-primary-content shadow-lg ring-1 ring-white/10 text-base font-semibold touch-manipulation",
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
    <!-- Mobile: Full-screen modal overlay, Desktop: positioned panel -->
    <div class="fixed inset-0 sm:absolute sm:inset-auto sm:bottom-full sm:left-0 sm:mb-2 z-50">
      <!-- Mobile backdrop -->
      <div class="sm:hidden fixed inset-0 bg-black/50" phx-click="toggle_console"></div>
      <!-- Panel -->
      <div class="fixed bottom-0 left-0 right-0 sm:relative sm:w-[730px] max-h-[85vh] sm:max-h-[70vh] bg-base-100 rounded-t-xl sm:rounded-lg shadow-xl border border-base-300 flex flex-col">
        <!-- Mobile drag handle -->
        <div class="sm:hidden flex justify-center py-2">
          <div class="w-10 h-1 bg-base-content/20 rounded-full"></div>
        </div>
        <!-- Tab bar -->
        <div class="flex border-b border-base-300">
          <button
            phx-click="set_console_tab"
            phx-value-tab="decks"
            class={[
              "flex-1 px-2 sm:px-4 py-2 text-xs sm:text-sm font-medium transition-colors touch-manipulation",
              if(@console_tab == :decks,
                do: "bg-base-200 text-base-content border-b-2 border-primary",
                else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
              )
            ]}
          >
            <span class="sm:hidden">Deck</span>
            <span class="hidden sm:inline">Logistics</span>
          </button>
          <button
            phx-click="set_console_tab"
            phx-value-tab="levels"
            class={[
              "flex-1 px-2 sm:px-4 py-2 text-xs sm:text-sm font-medium transition-colors touch-manipulation",
              if(@console_tab == :levels,
                do: "bg-base-200 text-base-content border-b-2 border-primary",
                else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
              )
            ]}
          >
            <span class="sm:hidden">Levels</span>
            <span class="hidden sm:inline">Research</span>
          </button>
          <button
            phx-click="set_console_tab"
            phx-value-tab="log"
            class={[
              "flex-1 px-2 sm:px-4 py-2 text-xs sm:text-sm font-medium transition-colors touch-manipulation",
              if(@console_tab == :log,
                do: "bg-base-200 text-base-content border-b-2 border-primary",
                else: "text-base-content/60 hover:text-base-content hover:bg-base-200/50"
              )
            ]}
          >
            <span class="sm:hidden">Log</span>
            <span class="hidden sm:inline">Newspaper</span>
          </button>
        </div>
        
    <!-- Tab content -->
        <div class="overflow-y-auto overflow-x-auto p-2 sm:p-4">
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
    </div>
    """
  end

  defp console_log_tab(assigns) do
    alias Oskol.Game.EventLog

    ~H"""
    <div class="flex justify-center">
      <div class="w-full max-w-2xl">
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
      </div>
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

    <div class="flex justify-center">
      <div class="inline-block">
        <div class="text-xs text-base-content/70 mb-2 sm:mb-3">
          {cards_remaining} cards left
          <%= if face_down_count > 0 do %>
            <span class="text-player/70 hidden sm:inline">
              ({face_down_count} face-down {if face_down_count == 1, do: "card", else: "cards"} in hand not highlighted)
            </span>
          <% end %>
        </div>

        <% suits = [:spades, :hearts, :clubs, :diamonds]
        ranks = [14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2] %>

        <!-- Cards in fixed 13-column grid per suit, duplicates in extra rows -->
        <!-- Mobile: scrollable horizontally with smaller cards -->
        <div class="space-y-2 sm:space-y-3 min-w-0">
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
        <div class="flex items-start gap-1 sm:gap-2">
          <!-- Suit count -->
          <div class="w-3 sm:w-4 text-center pt-1 text-[10px] sm:text-xs text-base-content/50 flex-shrink-0">
            {length(suit_cards)}
          </div>
          <!-- Fixed 13-column grid with extra rows for duplicates - scrollable on mobile -->
          <div class="flex-1 space-y-0.5 sm:space-y-1 overflow-x-auto">
            <%= for row_idx <- 0..(max_dupes - 1) do %>
              <div class="flex gap-0.5 sm:gap-1">
                <%= for rank <- ranks do %>
                  <% cards_at_rank = Map.get(cards_by_rank, rank, [])
                  card = Enum.at(cards_at_rank, row_idx) %>
                  <%= if card do %>
                    <% in_hand = card.id in hand_ids
                    is_face_down = card.id in face_down_ids

                    is_disabled =
                      card.rank in current_state.disabled_ranks or
                        card.suit in current_state.disabled_suits

                    # Face-down cards in hand should not be highlighted (treated like draw pile)
                    opacity = if in_hand and not is_face_down, do: "opacity-100", else: "opacity-40" %>
                    <.card_display
                      card={card}
                      class={"w-6 h-9 sm:w-12 sm:h-[72px] flex-shrink-0 #{opacity}"}
                      compact={true}
                      disabled={is_disabled}
                      enhancement_disabled={current_state.enhancements_disabled}
                    />
                  <% else %>
                    <div class="w-6 h-9 sm:w-12 sm:h-[72px] bg-base-300/20 rounded flex-shrink-0">
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
        </div>
      </div>
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
    ] %>

    <div class="flex justify-center">
      <div class="w-full max-w-2xl">
        <div class="space-y-1">
          <%= for hand_type <- hand_types do %>
        <% level = Map.get(current_state.skill_tree, hand_type, 1)
        stats = Oskol.Poker.Score.stats_at_level(hand_type, level)
        is_countered = hand_type in current_state.active_debuffs %>
        <div class={[
          "flex items-center justify-between py-1 px-2 rounded hover:bg-base-200",
          if(is_countered, do: "opacity-60", else: "")
        ]}>
          <div class="flex items-center gap-2">
            <span class="text-xs text-base-content/50 w-6">Lv{level}</span>
            <span class={["text-sm", if(is_countered, do: "line-through", else: "")]}>
              {Format.hand_name(hand_type)}
            </span>
            <%= if is_countered do %>
              <span class="text-xs text-error font-medium">(Countered)</span>
            <% end %>
          </div>
          <span class={[
            "text-xs",
            if(is_countered, do: "text-base-content/40 line-through", else: "text-base-content/70")
          ]}>
            {stats.base_chips} × {stats.multiplier}
          </span>
        </div>
          <% end %>
        </div>
      </div>
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
      <!-- Mobile: 2-line status bar at top -->
      <div class="sm:hidden grid grid-cols-[1fr_auto_1fr] items-center px-2 py-1.5 bg-base-200/50 text-xs gap-x-3">
        <% player_score = @player_state.current_round_score
        opponent_score = @opponent_state.current_round_score
        score_diff = abs(player_score - opponent_score) %>
        
    <!-- Left column: Round info (2 lines) -->
        <div class="flex flex-col">
          <span class="font-semibold">Round {@game_state.round_number}</span>
          <span class="text-base-content/60">
            <%= cond do %>
              <% @player_state.hands_remaining == 0 -> %>
                Round complete
              <% @player_state.hands_remaining == 1 -> %>
                Final hand
              <% true -> %>
                {@player_state.hands_remaining} hands left
            <% end %>
          </span>
        </div>
        
    <!-- Center column: Score diff (centered) -->
        <div class="flex items-center justify-center">
          <%= if score_diff > 0 do %>
            <span class={
              if player_score > opponent_score,
                do: "text-player font-semibold text-sm",
                else: "text-opponent font-semibold text-sm"
            }>
              {if player_score > opponent_score, do: "+", else: "-"}{score_diff}
            </span>
          <% else %>
            <span class="text-base-content/50">Tied</span>
          <% end %>
        </div>
        
    <!-- Right column: Player stats (2 lines) -->
        <div class="flex flex-col items-end gap-0.5">
          <!-- Opponent line -->
          <div class="flex items-center gap-1.5">
            <span class="text-opponent font-medium">{@opponent_name |> String.slice(0, 6)}</span>
            <div class="flex items-center gap-0.5">
              <span class="text-base-content/70">{@opponent_state.lives}</span>
              <.icon name="hero-heart-solid" class="w-3 h-3 text-base-content/50" />
            </div>
            <div class="flex items-center gap-0.5">
              <span class="text-base-content/70">{@opponent_state.discards_remaining}</span>
              <.icon name="hero-trash-solid" class="w-3 h-3 text-base-content/50" />
            </div>
          </div>
          <!-- Player line -->
          <div class="flex items-center gap-1.5">
            <span class="text-player font-medium">{@player_name |> String.slice(0, 6)}</span>
            <div class="flex items-center gap-0.5">
              <span class="text-base-content/70">{@player_state.lives}</span>
              <.icon name="hero-heart-solid" class="w-3 h-3 text-base-content/50" />
            </div>
            <div class="flex items-center gap-0.5">
              <span class="text-base-content/70">{@player_state.discards_remaining}</span>
              <.icon name="hero-trash-solid" class="w-3 h-3 text-base-content/50" />
            </div>
          </div>
        </div>
      </div>
      
    <!-- Mobile: Badges row (only shows if there are any active effects) -->
      <% player_badges = get_sabotage_badges(@player_state)
      opponent_badges = get_sabotage_badges(@opponent_state)

      has_any_badges =
        @player_state.active_debuffs != [] or @opponent_state.active_debuffs != [] or
          player_badges != [] or opponent_badges != [] %>
      <%= if has_any_badges do %>
        <div class="sm:hidden flex flex-wrap gap-1 px-2 py-1.5 bg-base-200/30 border-t border-base-300/50">
          <!-- Player debuffs (bad for you) -->
          <%= if @player_state.active_debuffs != [] do %>
            <div class="flex items-center gap-1 px-2 py-0.5 bg-player rounded text-[10px]">
              <.icon name="hero-hand-thumb-down-solid" class="w-3 h-3 text-sky-900" />
              <span class="font-semibold text-sky-900">
                {Enum.map(@player_state.active_debuffs, &Format.hand_name/1) |> Enum.join(", ")} blocked
              </span>
            </div>
          <% end %>

          <%= for badge <- player_badges do %>
            <div class="flex items-center gap-1 px-2 py-0.5 bg-player rounded text-[10px]">
              <.icon name="hero-hand-thumb-down-solid" class="w-3 h-3 text-sky-900" />
              <span class="font-semibold text-sky-900">{badge.name}</span>
            </div>
          <% end %>
          
    <!-- Opponent debuffs (good for you) -->
          <%= if @opponent_state.active_debuffs != [] do %>
            <div class="flex items-center gap-1 px-2 py-0.5 bg-opponent rounded text-[10px]">
              <.icon name="hero-hand-thumb-up-solid" class="w-3 h-3 text-orange-900" />
              <span class="font-semibold text-orange-900">
                {Enum.map(@opponent_state.active_debuffs, &Format.hand_name/1) |> Enum.join(", ")} blocked
              </span>
            </div>
          <% end %>

          <%= for badge <- opponent_badges do %>
            <div class="flex items-center gap-1 px-2 py-0.5 bg-opponent rounded text-[10px]">
              <.icon name="hero-hand-thumb-up-solid" class="w-3 h-3 text-orange-900" />
              <span class="font-semibold text-orange-900">{badge.name}</span>
            </div>
          <% end %>
        </div>
      <% end %>
      
    <!-- Desktop: Round info - top left -->
      <div class="hidden sm:block absolute top-4 left-4 text-left text-base-content">
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
        round_complete = @player_state.hands_remaining == 0 %>
        <%= cond do %>
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
        <!-- Effects on YOU (player color) -->
        <%= if @player_state.active_debuffs != [] do %>
          <div class="flex items-center gap-1 mt-2 px-2 py-1 bg-player rounded">
            <span class="text-xs font-semibold text-sky-900">
              {Enum.map(@player_state.active_debuffs, &Format.hand_name/1) |> Enum.join(", ")} blocked
            </span>
          </div>
        <% end %>

        <%= for badge <- get_sabotage_badges(@player_state) do %>
          <div class="group relative flex items-center gap-1 mt-1 px-2 py-1 bg-player rounded cursor-default">
            <span class="text-xs font-semibold text-sky-900">{badge.name}</span>
            <div class="absolute top-1/2 -translate-y-1/2 left-full ml-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
              {badge.tooltip}
            </div>
          </div>
        <% end %>

    <!-- Effects on OPPONENT (opponent color) -->
        <%= if @opponent_state.active_debuffs != [] do %>
          <div class="flex items-center gap-1 mt-1 px-2 py-1 bg-opponent rounded">
            <span class="text-xs font-semibold text-orange-900">
              {Enum.map(@opponent_state.active_debuffs, &Format.hand_name/1) |> Enum.join(", ")} blocked
            </span>
          </div>
        <% end %>

        <%= for badge <- get_sabotage_badges(@opponent_state) do %>
          <div class="group relative flex items-center gap-1 mt-1 px-2 py-1 bg-opponent rounded cursor-default">
            <span class="text-xs font-semibold text-orange-900">{badge.name}</span>
            <div class="absolute top-1/2 -translate-y-1/2 left-full ml-2 px-2 py-1 bg-base-300 text-xs rounded shadow-lg opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap pointer-events-none">
              {badge.tooltip}
            </div>
          </div>
        <% end %>
      </div>
      
    <!-- Desktop: Opponent status - top right -->
      <div class="hidden sm:flex absolute top-4 right-4 flex-col items-end gap-0.5 text-base-content">
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
      
    <!-- Desktop: Player status - bottom right -->
      <div class="hidden sm:flex absolute bottom-4 right-4 flex-col items-end gap-0.5 text-base-content">
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
          <% assigns[:active_console] && !@viewing_results -> %>
            <.console_content_inline
              active_console={@active_console}
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

          <% @viewing_results && @game_state.last_hand_results != nil -> %>
            <% player_result = @game_state.last_hand_results[@player_id] %>
            <% opponent_result = @game_state.last_hand_results[@opponent_id] %>
            <.animated_score_display
              game_state={@game_state}
              player_id={@player_id}
              opponent_id={@opponent_id}
              player_name={@player_name}
              opponent_name={@opponent_name}
              animation_phase={@score_animation_phase}
              animation_card_index={@score_animation_card_index}
              player_disabled_ranks={player_result.disabled_ranks}
              player_disabled_suits={player_result.disabled_suits}
              player_enhancements_disabled={player_result.enhancements_disabled}
              opponent_disabled_ranks={opponent_result.disabled_ranks}
              opponent_disabled_suits={opponent_result.disabled_suits}
              opponent_enhancements_disabled={opponent_result.enhancements_disabled}
            />
          <% @player_state.locked_in_hand != nil && @opponent_state.locked_in_hand == nil -> %>
            <.waiting_for_opponent
              player_name={@player_name}
              hand={@player_state.locked_in_hand}
              face_down_card_ids={@player_state.face_down_card_ids}
              disabled_ranks={@player_state.disabled_ranks}
              disabled_suits={@player_state.disabled_suits}
              enhancements_disabled={@player_state.enhancements_disabled}
            />
          <% @opponent_state.locked_in_hand != nil && @player_state.locked_in_hand == nil -> %>
            <.opponent_locked_notice />
          <% true -> %>
            <!-- Round info shown in top left, nothing else to display -->
            <div></div>
        <% end %>
      </div>

      <%= if assigns[:active_console] && !@viewing_results do %>
        <div class="absolute inset-0 bg-black/10 backdrop-blur-[2px] -z-10
                    transition-opacity duration-200"
             phx-click="close_console">
        </div>
      <% end %>
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
    <div class="text-center space-y-4 sm:space-y-8 px-2 sm:px-0">
      <!-- Opponent's breakdown (always on top) -->
      <.score_breakdown_row
        result={@opponent_result}
        player_name={@opponent_name}
        animation_state={@opponent_state || %{phase: :base, cards_scored: 0}}
        is_opponent={true}
        skill_tree={@game_state.players[@opponent_id].skill_tree}
        disabled_ranks={@opponent_disabled_ranks}
        disabled_suits={@opponent_disabled_suits}
        enhancements_disabled={@opponent_enhancements_disabled}
      />
      
    <!-- Player's breakdown (always on bottom, near your cards) -->
      <.score_breakdown_row
        result={@player_result}
        player_name={@player_name}
        animation_state={@player_state || %{phase: :base, cards_scored: 0}}
        is_opponent={false}
        skill_tree={@game_state.players[@player_id].skill_tree}
        disabled_ranks={@player_disabled_ranks}
        disabled_suits={@player_disabled_suits}
        enhancements_disabled={@player_enhancements_disabled}
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
      |> assign_new(:disabled_ranks, fn -> [] end)
      |> assign_new(:disabled_suits, fn -> [] end)
      |> assign_new(:enhancements_disabled, fn -> false end)

    ~H"""
    <div class={if @is_opponent, do: "", else: ""}>
      <!-- Hand type header -->
      <div class="text-xs sm:text-sm text-base-content/80 mb-1 sm:mb-2">
        {@hand_type_text}
      </div>
      
    <!-- Cards display - responsive sizing -->
      <div class="flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3">
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
            end

          is_disabled = card.rank in @disabled_ranks or card.suit in @disabled_suits %>
          <div class="relative">
            <.card_display
              card={card}
              class={"w-9 h-[52px] sm:w-16 sm:h-24 #{card_class}"}
              disabled={is_disabled}
              enhancement_disabled={@enhancements_disabled}
              compact={true}
            />
            <%= if card_breakdown do %>
              <div class="chip-float chip-float-chips text-[10px] sm:text-sm">
                +{card_breakdown.chip_value + card_breakdown.bonus_chips}
              </div>
              <%= if card_breakdown.bonus_mult > 0 do %>
                <div class="chip-float chip-float-mult text-[10px] sm:text-sm" style="top: 8px;">
                  +{card_breakdown.bonus_mult}x
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Formula display - responsive sizing -->
      <div class="flex items-center justify-center gap-2 sm:gap-3 text-sm sm:text-lg font-mono">
        <span class="text-blue-400 font-bold">{@running_chips}</span>
        <span class="text-base-content/60">×</span>
        <span class="text-red-400 font-bold">{@running_mult}</span>
        <%= if @show_final do %>
          <span class="text-base-content/60">=</span>
          <span class="text-yellow-400 font-bold text-base sm:text-xl score-reveal">
            {@running_score}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  def waiting_for_opponent(assigns) do
    # Sort hand by rank for consistent display
    sorted_hand = sort_cards(assigns.hand, :rank)

    assigns =
      assigns
      |> assign(:sorted_hand, sorted_hand)
      |> assign_new(:disabled_ranks, fn -> [] end)
      |> assign_new(:disabled_suits, fn -> [] end)
      |> assign_new(:enhancements_disabled, fn -> false end)
      |> assign_new(:face_down_card_ids, fn -> [] end)

    ~H"""
    <div class="text-center space-y-4 sm:space-y-8 px-2 sm:px-0">
      <!-- Opponent placeholder - same height as score breakdown row -->
      <div>
        <div class="text-xs sm:text-sm text-base-content/50 mb-1 sm:mb-2">
          Waiting for opponent...
        </div>
        <div class="flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3">
          <!-- Invisible placeholder cards to reserve space -->
          <%= for _i <- 1..length(@sorted_hand) do %>
            <div class="w-9 h-[52px] sm:w-16 sm:h-24 opacity-0"></div>
          <% end %>
        </div>
        <div class="h-5 sm:h-7"></div>
        <!-- placeholder for formula row -->
      </div>
      
    <!-- Player's locked hand -->
      <div>
        <div class="text-xs sm:text-sm text-base-content/80 mb-1 sm:mb-2">&nbsp;</div>
        <div class="flex gap-1 sm:gap-2 justify-center mb-2 sm:mb-3">
          <%= for card <- @sorted_hand do %>
            <% is_disabled = card.rank in @disabled_ranks or card.suit in @disabled_suits %>
            <% is_face_down = card.id in @face_down_card_ids %>
            <.card_display
              card={card}
              class="w-9 h-[52px] sm:w-16 sm:h-24"
              face_down={is_face_down}
              disabled={is_disabled}
              enhancement_disabled={@enhancements_disabled}
              compact={true}
            />
          <% end %>
        </div>
        <div class="h-5 sm:h-7"></div>
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
      |> assign_new(:disabled, fn -> false end)
      |> assign_new(:enhancement_disabled, fn -> false end)

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
          "absolute font-bold rounded shadow-lg",
          if(@enhancement_disabled,
            do: "bg-gray-500 text-gray-300 line-through",
            else: "bg-purple-600 text-white"
          ),
          if(@compact,
            do: "top-px right-px text-[8px] px-0.5 py-0",
            else: "top-0.5 right-0.5 text-xs px-1.5 py-0.5"
          )
        ]}>
          {@enhancement_text}
        </div>
      <% end %>
      <%= if @disabled and not @face_down do %>
        <div class="absolute inset-0 flex items-center justify-center pointer-events-none">
          <svg class="w-3/4 h-3/4 text-pink-600/15" viewBox="0 0 100 100">
            <line
              x1="20"
              y1="20"
              x2="80"
              y2="80"
              stroke="currentColor"
              stroke-width="12"
              stroke-linecap="round"
            />
            <line
              x1="80"
              y1="20"
              x2="20"
              y2="80"
              stroke="currentColor"
              stroke-width="12"
              stroke-linecap="round"
            />
          </svg>
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

                              is_disabled =
                                card.rank in current_state.disabled_ranks or
                                  card.suit in current_state.disabled_suits

                              top_offset = index * 20 %>
                              <div class="absolute" style={"top: #{top_offset}px;"}>
                                <.card_display
                                  card={card}
                                  class={"w-16 h-24 #{opacity_class}"}
                                  disabled={is_disabled}
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
                  hand_name = Format.hand_name(hand_type)
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

  # New console system - emoji buttons at mid-left
  def console_buttons(assigns) do
    ~H"""
    <!-- Fixed console buttons at mid-left of screen, hidden on mobile when console is active -->
    <div class={[
      "fixed left-px top-1/2 -translate-y-1/2 z-40",
      if(@active_console != nil, do: "hidden sm:block", else: "")
    ]}>
      <div class="flex flex-col gap-2 sm:gap-3">
        <!-- Deck Button -->
        <button
          phx-click="toggle_console"
          phx-value-window="deck"
          disabled={assigns[:viewing_results] || false}
          class={[
            "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm",
            if(assigns[:viewing_results] || false,
              do: "opacity-30 cursor-not-allowed pointer-events-none bg-gray-900/30",
              else: if(@active_console == :deck,
                do: "bg-gray-900/95 scale-110 translate-x-1",
                else: "bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
              )
            )
          ]}
          title="View Deck"
        >
          <.icon
            name={if @active_console == :deck, do: "hero-square-3-stack-3d-solid", else: "hero-square-3-stack-3d"}
            class="w-6 h-6 sm:w-7 sm:h-7 text-blue-600"
          />
        </button>

        <!-- Levels Button -->
        <button
          phx-click="toggle_console"
          phx-value-window="levels"
          disabled={assigns[:viewing_results] || false}
          class={[
            "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm",
            if(assigns[:viewing_results] || false,
              do: "opacity-30 cursor-not-allowed pointer-events-none bg-gray-900/30",
              else: if(@active_console == :levels,
                do: "bg-gray-900/95 scale-110 translate-x-1",
                else: "bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
              )
            )
          ]}
          title="View Levels"
        >
          <.icon
            name={if @active_console == :levels, do: "hero-chart-bar-solid", else: "hero-chart-bar"}
            class="w-6 h-6 sm:w-7 sm:h-7 text-green-600"
          />
        </button>

        <!-- Log Button -->
        <button
          phx-click="toggle_console"
          phx-value-window="log"
          disabled={assigns[:viewing_results] || false}
          class={[
            "px-2 py-1.5 sm:px-3 sm:py-2 rounded-r-xl transition-all shadow-xl text-xl sm:text-2xl touch-manipulation backdrop-blur-sm",
            if(assigns[:viewing_results] || false,
              do: "opacity-30 cursor-not-allowed pointer-events-none bg-gray-900/30",
              else: if(@active_console == :log,
                do: "bg-gray-900/95 scale-110 translate-x-1",
                else: "bg-gray-900/20 hover:bg-gray-900/40 hover:scale-105"
              )
            )
          ]}
          title="View Log"
        >
          <.icon
            name={if @active_console == :log, do: "hero-newspaper-solid", else: "hero-newspaper"}
            class="w-6 h-6 sm:w-7 sm:h-7 text-amber-600"
          />
        </button>
      </div>
    </div>
    """
  end

  # Inline console content (appears in centerboard)
  def console_content_inline(assigns) do
    ~H"""
    <!-- Container with simple fade-in animation, pinned top offset -->
    <div class="w-full h-full flex flex-col items-center pt-8 sm:pt-16 animate-fadeInScale">
      <!-- Desktop title (pinned position) -->
      <div class="hidden sm:block text-center mb-6">
        <h2 class="flex items-center justify-center gap-3 text-xl font-semibold text-white/90">
          <%= case @active_console do %>
            <% :deck -> %>
              <.icon name="hero-square-3-stack-3d-solid" class="w-6 h-6 text-blue-400" />
              Deck
            <% :levels -> %>
              <.icon name="hero-chart-bar-solid" class="w-6 h-6 text-green-400" />
              Levels
            <% :log -> %>
              <.icon name="hero-newspaper-solid" class="w-6 h-6 text-amber-400" />
              Log
          <% end %>
        </h2>
      </div>

      <!-- Mobile-only header with close button -->
      <div class="sm:hidden w-full flex items-center justify-between px-4 pb-3 mb-4">
        <span class="flex items-center gap-2 text-sm font-semibold text-white/90">
          <%= case @active_console do %>
            <% :deck -> %>
              <.icon name="hero-square-3-stack-3d-solid" class="w-4 h-4 text-blue-400" />
              Deck
            <% :levels -> %>
              <.icon name="hero-chart-bar-solid" class="w-4 h-4 text-green-400" />
              Levels
            <% :log -> %>
              <.icon name="hero-newspaper-solid" class="w-4 h-4 text-amber-400" />
              Log
          <% end %>
        </span>
        <button
          phx-click="close_console"
          class="text-white/60 hover:text-white text-xl px-2"
        >
          ✕
        </button>
      </div>

      <!-- Scrollable content area - centered and max-width constrained -->
      <div class="overflow-y-auto overflow-x-auto flex-1 w-full max-w-6xl px-4 sm:px-8">
        <%= case @active_console do %>
          <% :deck -> %>
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

          <% :log -> %>
            <.console_log_tab
              event_log={@event_log}
              player_names={@game_state.player_names}
              player_id={@player_id}
            />
        <% end %>
      </div>
    </div>
    """
  end
end
