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
    </style>
    """
  end

  def game_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-300">
      <!-- Opponent Stats Bar -->
      <div class="flex justify-center py-3 bg-base-200/40 backdrop-blur-sm">
        <.player_stats player_state={@opponent_state} />
      </div>
      
    <!-- Top 25% - Opponent Cards -->
      <div class="flex-1 flex flex-col justify-end p-4 bg-base-200/40">
        <.opponent_cards
          opponent_state={@opponent_state}
          opponent_card_sort={@opponent_card_sort}
          opponent_new_card_ids={@opponent_new_card_ids}
        />
      </div>
      
    <!-- Middle 50% - Playing Area -->
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
        />
      </div>
      
    <!-- Player Cards -->
      <div class="flex-1 flex flex-col justify-start p-4 bg-base-200/40">
        <.player_cards
          player_state={@player_state}
          selected_card_ids={@selected_card_ids}
          your_card_sort={@your_card_sort}
          new_card_ids={@new_card_ids}
          action_in_progress={@action_in_progress}
        />
      </div>
      
    <!-- Player Stats Bar -->
      <div class="flex justify-center py-3 bg-base-200/40 backdrop-blur-sm">
        <.player_stats player_state={@player_state} />
      </div>
      
    <!-- Action Bar -->
      <.action_bar
        player_state={@player_state}
        selected_card_ids={@selected_card_ids}
        card_sort={@your_card_sort}
        action_in_progress={@action_in_progress}
        viewing_results={@viewing_results}
      />
    </div>
    """
  end

  def opponent_cards(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-4 justify-center mb-2">
      <%= for card <- sort_cards(@opponent_state.card_piles.hand_pile, @opponent_card_sort) do %>
        <% is_new = card.id in @opponent_new_card_ids %>
        <.card_display
          card={card}
          class={["w-28 h-40", if(is_new, do: "new-card", else: "")]}
        />
      <% end %>
    </div>
    """
  end

  def player_cards(assigns) do
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
          />
        </button>
      <% end %>
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
          <.icon name="hero-play" class="w-5 h-5" />
          <span>{@player_state.hands_remaining}</span>
        </div>
        <div class="flex items-center gap-1">
          <.icon name="hero-trash" class="w-5 h-5" />
          <span>{@player_state.discards_remaining}</span>
        </div>
        <div class="flex items-center gap-1">
          <.icon name="hero-star" class="w-5 h-5" />
          <span>{@player_state.current_round_score}</span>
        </div>
      </div>

      <%= if @player_state.active_debuffs != [] do %>
        <div class="flex items-center gap-2 px-3 py-1 bg-error/10 rounded-lg border border-error/30">
          <.icon name="hero-x-circle" class="w-4 h-4 text-error" />
          <span class="text-xs font-semibold text-error">Denied:</span>
          <div class="flex gap-1">
            <%= for hand_type <- @player_state.active_debuffs do %>
              <span class="text-xs px-2 py-0.5 bg-error/20 rounded text-error font-medium">
                {format_hand_name_short(hand_type)}
              </span>
            <% end %>
          </div>
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
      <!-- Left: Sort, History, and Deck Buttons (always visible) -->
      <div class="flex items-center gap-2">
        <button
          phx-click="toggle_history"
          class="px-4 py-2 bg-base-100/60 hover:bg-base-100 rounded transition-all text-base-content/80 hover:text-base-content shadow-sm"
        >
          Game Log
        </button>
        <button
          phx-click="toggle_deck"
          class="px-4 py-2 bg-base-100/60 hover:bg-base-100 rounded transition-all text-base-content/80 hover:text-base-content shadow-sm"
        >
          View Cards
        </button>
        <button
          phx-click="toggle_levels"
          class="px-4 py-2 bg-base-100/60 hover:bg-base-100 rounded transition-all text-base-content/80 hover:text-base-content shadow-sm"
        >
          View Levels
        </button>
        <button
          phx-click="toggle_card_sort"
          class="px-4 py-2 bg-base-100/60 hover:bg-base-100 rounded transition-all text-base-content/80 hover:text-base-content shadow-sm"
        >
          Sort Cards
        </button>
      </div>

      <%= if @viewing_results do %>
        <!-- Right: Skip Button with progress fill -->
        <button
          phx-click="dismiss_results"
          class="skip-button-5s px-4 py-2 rounded bg-base-100 hover:bg-base-200 text-base-content transition-colors"
        >
          <span class="skip-button-text">Skip Hand Summary</span>
        </button>
      <% else %>
        <!-- Right: Action Buttons -->
        <div class="flex items-center gap-4">
          <button
            phx-click="discard_cards"
            disabled={
              @action_in_progress || length(selected_card_ids) == 0 ||
                @player_state.discards_remaining == 0 || is_locked_in
            }
            class={[
              "px-4 py-2 rounded transition-colors bg-error hover:bg-error/90 text-error-content",
              if(
                @action_in_progress || length(selected_card_ids) == 0 ||
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
            disabled={@action_in_progress || length(selected_card_ids) == 0 || is_locked_in}
            class={[
              "px-4 py-2 rounded transition-colors bg-primary hover:bg-primary/90 text-primary-content",
              if(
                @action_in_progress || length(selected_card_ids) == 0 || is_locked_in,
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
      <% end %>
    </div>
    """
  end

  def playing_area(assigns) do
    ~H"""
    <div class="h-full relative">
      <!-- Round info bar -->
      <div class="absolute top-4 left-4 right-4 flex justify-between items-center text-base-content text-lg">
        <div>Round {@game_state.round_number}</div>

        <% player_score = @player_state.current_round_score
        opponent_score = @opponent_state.current_round_score
        score_diff = abs(player_score - opponent_score) %>

        <%= if score_diff > 0 do %>
          <div class="text-base">
            <%= if player_score > opponent_score do %>
              You are up by {score_diff} points
            <% else %>
              {@opponent_name} is up by {score_diff} points
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Centered content -->
      <div class="h-full flex flex-col justify-center">
        <%= cond do %>
          <% @viewing_results && @game_state.last_hand_results != nil -> %>
            <.hand_results_display
              game_state={@game_state}
              player_id={@player_id}
              opponent_id={@opponent_id}
              player_name={@player_name}
              opponent_name={@opponent_name}
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
        color="text-error"
        show_result={true}
        is_current_player={false}
      />

      <% my_result = @game_state.last_hand_results[@player_id] %>
      <.locked_hand_display
        player_name={@player_name}
        hand={my_result.hand}
        hand_type={my_result.hand_type}
        score={my_result.score}
        color="text-primary"
        show_result={true}
        is_current_player={true}
      />
    </div>
    """
  end

  def waiting_for_opponent(assigns) do
    ~H"""
    <div class="text-center">
      <.locked_hand_display
        player_name={@player_name}
        hand={@hand}
        hand_type={nil}
        score={nil}
        color="text-primary"
        show_result={false}
        is_current_player={true}
      />
      <div class="text-xs text-base-content/50 mt-2">Waiting for opponent...</div>
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
        <%= for card <- @hand do %>
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
  """
  def card_display(assigns) do
    # Set defaults
    assigns =
      assigns
      |> assign_new(:class, fn -> "" end)
      |> assign_new(:show_enhancement, fn -> true end)

    enhancement_text =
      if assigns.show_enhancement do
        case assigns.card.enhancement do
          {:bonus_chips, amount} -> "+#{amount}c"
          {:bonus_mult, amount} -> "+#{amount}x"
          nil -> nil
        end
      else
        nil
      end

    assigns = assign(assigns, :enhancement_text, enhancement_text)

    ~H"""
    <div class={"rounded overflow-hidden relative #{@class}"}>
      <img src={card_to_png_url(@card)} class="w-full h-full" />
      <%= if @enhancement_text do %>
        <div class="absolute top-0.5 right-0.5 bg-purple-600 text-white text-xs font-bold px-1.5 py-0.5 rounded shadow-lg">
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
        phx-click="toggle_deck"
      >
        <div
          class="bg-base-100 rounded-lg shadow-xl p-6 max-w-6xl w-full max-h-[90vh] overflow-y-auto border border-base-300"
          phx-click="noop"
        >
          <div class="flex justify-between items-center mb-6">
            <!-- Toggle buttons serve as title -->
            <div class="flex gap-2">
              <button
                phx-click="toggle_deck_view"
                class={[
                  "px-6 py-2 rounded-lg font-semibold transition-colors text-lg",
                  if(@viewing_own_deck,
                    do: "bg-primary text-primary-content",
                    else: "bg-base-200 text-base-content/70 hover:bg-base-300"
                  )
                ]}
              >
                Your Deck
              </button>
              <button
                phx-click="toggle_deck_view"
                class={[
                  "px-6 py-2 rounded-lg font-semibold transition-colors text-lg",
                  if(!@viewing_own_deck,
                    do: "bg-primary text-primary-content",
                    else: "bg-base-200 text-base-content/70 hover:bg-base-300"
                  )
                ]}
              >
                {@opponent_name}'s Deck
              </button>
            </div>

            <button
              phx-click="toggle_deck"
              class="text-base-content/60 hover:text-base-content text-2xl"
            >
              ×
            </button>
          </div>

          <% # Select which state to show
          current_state = if @viewing_own_deck, do: @player_state, else: @opponent_state

          # Organize cards by location
          discard_ids = MapSet.new(Enum.map(current_state.card_piles.discard_pile, & &1.id))
          draw_pile = current_state.card_piles.draw_pile
          hand_pile = current_state.card_piles.hand_pile
          discard_pile = current_state.card_piles.discard_pile

          # Combine all cards
          all_cards = draw_pile ++ hand_pile ++ discard_pile

          # Group by suit
          cards_by_suit = Enum.group_by(all_cards, & &1.suit)
          suits = [:spades, :hearts, :clubs, :diamonds] %>
          
    <!-- Render each suit as a row -->
          <%= for suit <- suits do %>
            <% suit_cards = Map.get(cards_by_suit, suit, []) %>
            <%= if length(suit_cards) > 0 do %>
              <% # Count non-discarded cards
              non_discarded_count = Enum.count(suit_cards, fn card -> card.id not in discard_ids end) %>

              <div class="mb-4">
                <div class="text-sm text-base-content/70 mb-1 font-medium">
                  {suit |> to_string() |> String.capitalize()}: {non_discarded_count} remaining
                </div>
                <div class="flex flex-wrap gap-2">
                  <%= for card <- Enum.sort_by(suit_cards, & &1.rank, :desc) do %>
                    <% in_discard = card.id in discard_ids
                    opacity_class = if in_discard, do: "opacity-30", else: "opacity-100" %>
                    <.card_display
                      card={card}
                      class={"w-16 h-22 #{opacity_class}"}
                    />
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
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
        phx-click="toggle_levels"
      >
        <div
          class="bg-base-100 rounded-lg shadow-xl p-6 max-w-5xl w-full max-h-[90vh] overflow-y-auto border border-base-300"
          phx-click="noop"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-2xl font-bold text-base-content">Player Levels</h2>
            <button
              phx-click="toggle_levels"
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
          } %>
          
    <!-- Two-column layout: Player vs Opponent -->
          <div class="grid grid-cols-2 gap-6 mb-4">
            <!-- Player Column -->
            <div>
              <h3 class="text-xl font-semibold text-primary mb-4 text-center">You</h3>
              <%= for hand_type <- hand_types do %>
                <% player_level = Map.get(@player_state.skill_tree, hand_type, 1)
                stats = Oskol.Poker.Score.stats_at_level(hand_type, player_level)
                hand_name = hand_names[hand_type] %>

                <div class="mb-3 p-3 bg-base-200 rounded border border-base-300">
                  <div class="font-semibold text-base-content mb-1">{hand_name}</div>
                  <div class="text-sm text-base-content/70">
                    <div>{stats.base_chips} chips × {stats.multiplier} mult</div>
                    <div class="mt-1 text-primary font-medium">Level: {player_level}</div>
                  </div>
                </div>
              <% end %>
            </div>
            
    <!-- Opponent Column -->
            <div>
              <h3 class="text-xl font-semibold text-error mb-4 text-center">{@opponent_name}</h3>
              <%= for hand_type <- hand_types do %>
                <% opponent_level = Map.get(@opponent_state.skill_tree, hand_type, 1)
                stats = Oskol.Poker.Score.stats_at_level(hand_type, opponent_level)
                hand_name = hand_names[hand_type] %>

                <div class="mb-3 p-3 bg-base-200 rounded border border-base-300">
                  <div class="font-semibold text-base-content mb-1">{hand_name}</div>
                  <div class="text-sm text-base-content/70">
                    <div>{stats.base_chips} chips × {stats.multiplier} mult</div>
                    <div class="mt-1 text-error font-medium">Level: {opponent_level}</div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
