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
    </style>
    """
  end

  def game_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen">
      <!-- Opponent Stats Bar -->
      <div class="flex justify-center py-3" style="background-color: #FBFBFB;">
        <.player_stats player_state={@opponent_state} />
      </div>
      
    <!-- Top 25% - Opponent Cards -->
      <div class="flex-1 flex flex-col justify-end p-4" style="background-color: #FBFBFB;">
        <.opponent_cards
          opponent_state={@opponent_state}
          opponent_card_sort={@opponent_card_sort}
          opponent_new_card_ids={@opponent_new_card_ids}
        />
      </div>
      
    <!-- Middle 50% - Playing Area -->
      <div class="flex-[2] flex flex-col justify-start border-t border-b border-gray-300 bg-white">
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
      <div class="flex-1 flex flex-col justify-start p-4" style="background-color: #FBFBFB;">
        <.player_cards
          player_state={@player_state}
          selected_card_ids={@selected_card_ids}
          your_card_sort={@your_card_sort}
          new_card_ids={@new_card_ids}
          action_in_progress={@action_in_progress}
        />
      </div>
      
    <!-- Player Stats Bar -->
      <div class="flex justify-center py-3" style="background-color: #FBFBFB;">
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
        <div class={[
          "w-28 h-40 rounded overflow-hidden",
          if(is_new, do: "new-card", else: "")
        ]}>
          <img src={card_to_png_url(card)} class="w-full h-full" />
        </div>
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
            "transition-all w-28 h-40 rounded overflow-hidden",
            if(selected, do: "-translate-y-4", else: ""),
            if((at_limit && not selected) || is_locked_in,
              do: "opacity-50 cursor-not-allowed",
              else: ""
            ),
            if(is_new, do: "new-card", else: "")
          ]}
        >
          <img
            src={card_to_png_url(card)}
            class="w-full h-full"
          />
        </button>
      <% end %>
    </div>
    """
  end

  def player_stats(assigns) do
    ~H"""
    <div class="flex items-center gap-4 text-gray-800 text-lg">
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
    """
  end

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

    <div class="h-20 bg-white border-t border-gray-300 flex items-center justify-between px-8">
      <!-- Left: Sort, History, and Deck Buttons (always visible) -->
      <div class="flex items-center gap-2">
        <button
          phx-click="toggle_history"
          class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded transition-colors text-gray-800"
        >
          Game Log
        </button>
        <button
          phx-click="toggle_deck"
          class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded transition-colors text-gray-800"
        >
          Player Decks
        </button>
        <button
          phx-click="toggle_card_sort"
          class="px-4 py-2 bg-gray-200 hover:bg-gray-300 rounded transition-colors text-gray-800"
        >
          Toggle Card Sort
        </button>
      </div>

      <%= if @viewing_results do %>
        <!-- Right: Continue Button when showing results -->
        <button
          phx-click="dismiss_results"
          class="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded transition-colors text-white font-bold"
        >
          Continue
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
              "px-4 py-2 rounded transition-colors bg-red-600 hover:bg-red-700",
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
              "px-4 py-2 rounded transition-colors bg-blue-600 hover:bg-blue-700",
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
      <!-- Round number in top left -->
      <div class="absolute top-4 left-4 text-gray-800 text-lg">
        Round {@game_state.round_number}
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
        color="text-red-400"
        show_result={true}
        is_current_player={false}
      />

      <% my_result = @game_state.last_hand_results[@player_id] %>
      <.locked_hand_display
        player_name={@player_name}
        hand={my_result.hand}
        hand_type={my_result.hand_type}
        score={my_result.score}
        color="text-blue-400"
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
        color="text-blue-400"
        show_result={false}
        is_current_player={true}
      />
      <div class="text-xs text-gray-400 mt-2">Waiting for opponent...</div>
    </div>
    """
  end

  def opponent_locked_notice(assigns) do
    ~H"""
    <div class="text-center text-gray-400 text-sm">
      Opponent has locked in their hand
    </div>
    """
  end

  def round_info_display(assigns) do
    ~H"""
    <div class="text-gray-800 text-lg">
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
          <div class="flex items-center justify-center gap-2 text-sm text-gray-700 mb-2">
            <span>{String.capitalize(@player_name)}</span>
            <span class="text-gray-400">|</span>
            <span>{hand_type_text}</span>
            <span class="text-gray-400">|</span>
            <.icon name="hero-star" class="w-4 h-4" />
            <span>{@score}</span>
          </div>
        <% end %>
      <% end %>

      <div class="flex gap-2 justify-center mb-2">
        <%= for card <- @hand do %>
          <div class="w-20 h-28 rounded overflow-hidden">
            <img src={card_to_png_url(card)} class="w-full h-full" />
          </div>
        <% end %>
      </div>

      <%= if @show_result do %>
        <% hand_type_text =
          @hand_type |> Atom.to_string() |> String.replace("_", " ") |> String.upcase() %>
        <%= if @is_current_player do %>
          <div class="flex items-center justify-center gap-2 text-sm text-gray-700">
            <span>{hand_type_text}</span>
            <span class="text-gray-400">|</span>
            <.icon name="hero-star" class="w-4 h-4" />
            <span>{@score}</span>
          </div>
        <% end %>
      <% else %>
        <div class="text-xs text-gray-400">Locked In</div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  def card_to_png_url(%Card{rank: rank, suit: suit}) do
    rank_str =
      case rank do
        14 -> "A"
        13 -> "K"
        12 -> "Q"
        11 -> "J"
        10 -> "0"
        n -> Integer.to_string(n)
      end

    suit_str =
      case suit do
        :hearts -> "H"
        :diamonds -> "D"
        :clubs -> "C"
        :spades -> "S"
      end

    "https://deckofcardsapi.com/static/img/#{rank_str}#{suit_str}.png"
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
        class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
        phx-click="toggle_deck"
      >
        <div
          class="bg-white rounded-lg p-6 max-w-6xl w-full max-h-[90vh] overflow-y-auto"
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
                    do: "bg-gray-900 text-white",
                    else: "bg-gray-200 text-gray-700 hover:bg-gray-300"
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
                    do: "bg-gray-900 text-white",
                    else: "bg-gray-200 text-gray-700 hover:bg-gray-300"
                  )
                ]}
              >
                {@opponent_name}'s Deck
              </button>
            </div>

            <button
              phx-click="toggle_deck"
              class="text-gray-500 hover:text-gray-700 text-2xl"
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
                <div class="text-sm text-gray-600 mb-1 font-medium">
                  <%= suit |> to_string() |> String.capitalize() %>: <%= non_discarded_count %> remaining
                </div>
                <div class="flex flex-wrap gap-2">
                  <%= for card <- Enum.sort_by(suit_cards, & &1.rank, :desc) do %>
                    <% in_discard = card.id in discard_ids %>
                    <div class={[
                      "w-16 h-22 rounded overflow-hidden",
                      if(in_discard, do: "opacity-30", else: "opacity-100")
                    ]}>
                      <img src={card_to_png_url(card)} class="w-full h-full" />
                    </div>
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
end
