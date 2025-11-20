defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components for the turn-based upgrade system.
  """
  use OskolWeb, :html

  def shop_screen(assigns) do
    ~H"""
    <div class="relative max-w-7xl mx-auto h-screen flex flex-col bg-base-100 p-6">
      <!-- Top Status Bar -->
      <%= if @game_state.shop_state do %>
        <.shop_status shop_state={@game_state.shop_state} player_names={@game_state.player_names} />
      <% end %>
      
    <!-- Center Preview Area (like the game board) -->
      <div class="flex-1 flex items-center justify-center">
        <%= if assigns[:previewing_card_index] != nil and @game_state.shop_state do %>
          <.card_preview_center
            shop_card={Enum.at(@game_state.shop_state.available_cards, @previewing_card_index)}
            card_index={@previewing_card_index}
            skill_tree={skill_tree_for_player(@player_id, assigns)}
            can_confirm={can_pick_card?(@game_state.shop_state, @player_id)}
            action_in_progress={@action_in_progress}
            pending_deck_builder={@game_state.shop_state.pending_deck_builder}
            deck_builder_selection={assigns[:deck_builder_selection]}
          />
        <% else %>
          <%= if @game_state.shop_state && shop_complete?(@game_state.shop_state) do %>
            <div class="text-center">
              <.ready_status_display
                player_name={@player_name}
                opponent_name={@opponent_name}
                player_ready={@player_state.ready_for_next_round}
                opponent_ready={@opponent_state.ready_for_next_round}
              />

              <div class="flex justify-center mt-6">
                <button
                  phx-click="mark_ready"
                  disabled={@action_in_progress or @player_state.ready_for_next_round}
                  class={[
                    "px-8 py-4 rounded font-bold text-xl transition-all shadow-lg",
                    if(@action_in_progress or @player_state.ready_for_next_round,
                      do: "bg-base-content/30 cursor-not-allowed opacity-50 text-base-content",
                      else: "bg-success hover:bg-success/90 text-success-content hover:scale-[1.02]"
                    )
                  ]}
                >
                  <%= if @player_state.ready_for_next_round do %>
                    Waiting for opponent...
                  <% else %>
                    I'm Ready!
                  <% end %>
                </button>
              </div>
            </div>
          <% else %>
            <div class="text-center">
              <%= cond do %>
                <% not @game_state.shop_state.first_pick_made and @game_state.shop_state.first_picker_id == @player_id -> %>
                  <div class="text-2xl text-success font-bold">Your turn to pick first!</div>
                <% @game_state.shop_state.first_pick_made and not @game_state.shop_state.second_pick_made and @game_state.shop_state.second_picker_id == @player_id -> %>
                  <div class="text-2xl text-success font-bold">Your turn to pick!</div>
                <% not @game_state.shop_state.first_pick_made -> %>
                  <div class="text-xl text-base-content/60">
                    Waiting for {@game_state.player_names[@game_state.shop_state.first_picker_id]} to pick first...
                  </div>
                <% @game_state.shop_state.first_pick_made and not @game_state.shop_state.second_pick_made -> %>
                  <div class="text-xl text-base-content/60">
                    Waiting for {@game_state.player_names[@game_state.shop_state.second_picker_id]} to pick...
                  </div>
                <% true -> %>
                  <div class="text-xl text-success">
                    Both players have picked! Moving to next round...
                  </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
      
    <!-- Bottom Cards Area (like gameplay hand) -->
      <%= if @game_state.shop_state && !shop_complete?(@game_state.shop_state) do %>
        <div class="pb-4">
          <.shop_cards_display
            shop_state={@game_state.shop_state}
            player_id={@player_id}
            previewing_card_index={assigns[:previewing_card_index]}
          />
        </div>
      <% end %>
    </div>
    """
  end

  defp shop_status(assigns) do
    ~H"""
    <div class="flex items-center justify-between text-sm pb-4 border-b border-base-300">
      <div class="text-base-content/80">
        Shop Round:
        <span class="text-primary font-bold">
          {@shop_state.current_round}/{@shop_state.total_rounds}
        </span>
      </div>
      <div class="text-base-content/80">
        First Pick:
        <span class="text-success font-bold">
          {@player_names[@shop_state.first_picker_id]}
        </span>
        <%= if @shop_state.first_pick_made do %>
          <span class="text-success ml-1">✓</span>
        <% end %>
      </div>
      <div class="text-base-content/80">
        Second Pick:
        <span class="text-info font-bold">
          {@player_names[@shop_state.second_picker_id]}
        </span>
        <%= if @shop_state.second_pick_made do %>
          <span class="text-success ml-1">✓</span>
        <% end %>
      </div>
    </div>
    """
  end

  defp shop_cards_display(assigns) do
    can_pick = can_pick_card?(assigns.shop_state, assigns.player_id)
    assigns = assign(assigns, :can_pick, can_pick)

    ~H"""
    <div>
      <%= if !@can_pick do %>
        <div class="text-center mb-3 text-base-content/60 text-sm font-semibold">
          Opponent is picking...
        </div>
      <% end %>
      <div class="grid grid-cols-6 gap-3 max-w-6xl mx-auto">
        <%= for {shop_card, index} <- Enum.with_index(@shop_state.available_cards) do %>
          <.shop_card_simple
            shop_card={shop_card}
            index={index}
            is_picked={index in @shop_state.picked_card_indices}
            is_previewing={@previewing_card_index == index}
            can_pick={@can_pick}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp skill_tree_for_player(player_id, assigns) do
    # Extract skill tree from game state for the given player
    player_state = assigns.game_state.players[player_id]
    player_state && player_state.skill_tree
  end

  defp shop_card_simple(assigns) do
    alias Oskol.Game.DeckBuilderCard

    {card_type, display_name, bg_color} =
      case assigns.shop_card do
        {:level_up, hand_type} ->
          {:level_up, format_hand_name(hand_type), "bg-accent/5"}

        {:action, action_card} ->
          hand_name = format_hand_name(action_card.target_hand)
          {:action, hand_name, "bg-error/5"}

        {:deck_builder, deck_builder_card} ->
          {:deck_builder, DeckBuilderCard.card_name(deck_builder_card), "bg-purple-500/5"}
      end

    # Add colored border if previewing
    border_class =
      if assigns[:is_previewing] do
        case card_type do
          :level_up -> "border-4 border-accent"
          :action -> "border-4 border-error"
          :deck_builder -> "border-4 border-purple-500"
        end
      else
        "border-2 border-base-300"
      end

    {badge_text, badge_color} =
      case card_type do
        :level_up -> {"LEVEL UP", "text-accent"}
        :action -> {"ACTION", "text-error"}
        :deck_builder -> {"DECK BUILDER", "text-purple-500"}
      end

    # Use different events for deck builders vs other cards
    click_event =
      if assigns[:can_pick] and not assigns[:is_picked] do
        case card_type do
          :deck_builder -> "preview_deck_builder"
          _ -> "preview_shop_card"
        end
      else
        nil
      end

    assigns =
      assigns
      |> assign(:card_type, card_type)
      |> assign(:display_name, display_name)
      |> assign(:bg_color, bg_color)
      |> assign(:border_class, border_class)
      |> assign(:badge_text, badge_text)
      |> assign(:badge_color, badge_color)
      |> assign(:click_event, click_event)

    ~H"""
    <button
      phx-click={@click_event}
      phx-value-index={@index}
      disabled={@is_picked or not @can_pick}
      class={[
        "aspect-[2/3] rounded-lg p-3 flex flex-col transition-all",
        @bg_color,
        @border_class,
        cond do
          @is_picked -> "opacity-30 cursor-not-allowed"
          @can_pick -> "hover:scale-105 hover:shadow-xl cursor-pointer"
          true -> "cursor-not-allowed"
        end
      ]}
    >
      <!-- Badge at top -->
      <div class={"text-[10px] font-bold uppercase tracking-wide #{@badge_color} mb-2"}>
        {@badge_text}
      </div>
      
    <!-- Card name centered -->
      <div class="flex-1 flex items-center justify-center">
        <div class="font-bold text-sm text-center text-base-content">
          {@display_name}
        </div>
      </div>

      <%= if @is_picked do %>
        <div class="text-center mt-2">
          <span class={"text-[10px] font-bold #{@badge_color}"}>PICKED</span>
        </div>
      <% end %>
    </button>
    """
  end

  defp format_hand_name(:high_card), do: "High Card"
  defp format_hand_name(:pair), do: "Pair"
  defp format_hand_name(:two_pair), do: "Two Pair"
  defp format_hand_name(:three_of_a_kind), do: "3 of a Kind"
  defp format_hand_name(:straight), do: "Straight"
  defp format_hand_name(:flush), do: "Flush"
  defp format_hand_name(:full_house), do: "Full House"
  defp format_hand_name(:four_of_a_kind), do: "4 of a Kind"
  defp format_hand_name(:straight_flush), do: "Str. Flush"

  defp ready_status_display(assigns) do
    ~H"""
    <div class="bg-base-300 rounded-lg p-4 mb-4">
      <div class="text-center text-sm text-base-content">
        <div class="mb-2">
          {@player_name}:
          <%= if @player_ready do %>
            <span class="text-success">✓ Ready</span>
          <% else %>
            <span class="text-warning">Not Ready</span>
          <% end %>
        </div>
        <div>
          {@opponent_name}:
          <%= if @opponent_ready do %>
            <span class="text-success">✓ Ready</span>
          <% else %>
            <span class="text-warning">Not Ready</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp shop_complete?(shop_state) do
    shop_state.current_round == shop_state.total_rounds and
      shop_state.first_pick_made and shop_state.second_pick_made
  end

  defp can_pick_card?(shop_state, player_id) do
    cond do
      not shop_state.first_pick_made and shop_state.first_picker_id == player_id ->
        true

      shop_state.first_pick_made and not shop_state.second_pick_made and
          shop_state.second_picker_id == player_id ->
        true

      true ->
        false
    end
  end

  defp card_preview_center(assigns) do
    ~H"""
    <div class="max-w-xl w-full">
      <%= case @shop_card do %>
        <% {:level_up, hand_type} -> %>
          <.level_up_preview
            hand_type={hand_type}
            skill_tree={@skill_tree}
            can_confirm={@can_confirm}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
          />
        <% {:action, action_card} -> %>
          <.action_preview
            action_card={action_card}
            can_confirm={@can_confirm}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
          />
        <% {:deck_builder, deck_builder_card} -> %>
          <.deck_builder_preview
            deck_builder_card={deck_builder_card}
            can_confirm={@can_confirm}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
            pending_deck_builder={@pending_deck_builder}
            deck_builder_selection={@deck_builder_selection}
          />
      <% end %>
    </div>
    """
  end

  defp level_up_preview(assigns) do
    current_level = Map.get(assigns.skill_tree, assigns.hand_type, 1)
    next_level = current_level + 1

    current_stats = Oskol.Poker.Score.stats_at_level(assigns.hand_type, current_level)
    next_stats = Oskol.Poker.Score.stats_at_level(assigns.hand_type, next_level)

    assigns =
      assigns
      |> assign(:current_level, current_level)
      |> assign(:next_level, next_level)
      |> assign(:current_stats, current_stats)
      |> assign(:next_stats, next_stats)
      |> assign(:hand_name, format_hand_name(assigns.hand_type))

    ~H"""
    <div class="text-center bg-base-200/50 rounded-xl p-8 border-2 border-accent/30">
      <!-- Badge -->
      <div class="text-xs font-bold uppercase tracking-wide text-accent mb-3">
        Level Up
      </div>
      
    <!-- Hand Name -->
      <h3 class="text-4xl font-bold text-accent mb-4">{@hand_name}</h3>
      
    <!-- Level Progress -->
      <div class="text-lg text-base-content/70 mb-8">
        Level {@current_level} → {@next_level}
      </div>
      
    <!-- Stats Comparison -->
      <div class="space-y-6 mb-8">
        <div class="flex items-center justify-between px-4">
          <span class="text-base-content/80 text-lg">Base Chips:</span>
          <div class="flex items-center gap-4">
            <span class="line-through opacity-50 text-lg">{@current_stats.base_chips}</span>
            <span class="text-base-content/40 text-xl">→</span>
            <span class="text-success font-bold text-2xl">{@next_stats.base_chips}</span>
          </div>
        </div>
        <div class="flex items-center justify-between px-4">
          <span class="text-base-content/80 text-lg">Multiplier:</span>
          <div class="flex items-center gap-4">
            <span class="line-through opacity-50 text-lg">{@current_stats.multiplier}x</span>
            <span class="text-base-content/40 text-xl">→</span>
            <span class="text-success font-bold text-2xl">{@next_stats.multiplier}x</span>
          </div>
        </div>
      </div>
      
    <!-- Action Buttons -->
      <%= if @can_confirm do %>
        <div class="flex justify-center">
          <button
            phx-click="confirm_shop_pick"
            phx-value-index={@card_index}
            disabled={@action_in_progress}
            class={[
              "px-8 py-3 rounded-lg font-bold transition-all shadow-lg",
              if(@action_in_progress,
                do: "bg-accent/30 cursor-not-allowed opacity-50",
                else: "bg-accent hover:bg-accent/90 text-accent-content hover:scale-[1.05]"
              )
            ]}
          >
            Confirm Pick
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp action_preview(assigns) do
    card_name = Oskol.Game.ActionCard.card_name(assigns.action_card)
    card_description = Oskol.Game.ActionCard.card_description(assigns.action_card)
    hand_name = format_hand_name(assigns.action_card.target_hand)

    assigns =
      assigns
      |> assign(:card_name, card_name)
      |> assign(:card_description, card_description)
      |> assign(:hand_name, hand_name)

    ~H"""
    <div class="text-center bg-base-200/50 rounded-xl p-8 border-2 border-error/30">
      <!-- Badge -->
      <div class="text-xs font-bold uppercase tracking-wide text-error mb-3">
        Action Card
      </div>
      
    <!-- Card Name -->
      <h3 class="text-4xl font-bold text-error mb-4">{@card_name}</h3>
      
    <!-- Target Hand -->
      <div class="text-lg text-base-content/70 mb-8">
        Targets: <span class="font-semibold text-error">{@hand_name}</span>
      </div>
      
    <!-- Description -->
      <div class="mb-8 px-4">
        <p class="text-base-content text-xl leading-relaxed">{@card_description}</p>
      </div>
      
    <!-- Action Buttons -->
      <%= if @can_confirm do %>
        <div class="flex justify-center">
          <button
            phx-click="confirm_shop_pick"
            phx-value-index={@card_index}
            disabled={@action_in_progress}
            class={[
              "px-8 py-3 rounded-lg font-bold transition-all shadow-lg",
              if(@action_in_progress,
                do: "bg-error/30 cursor-not-allowed opacity-50",
                else: "bg-error hover:bg-error/90 text-error-content hover:scale-[1.05]"
              )
            ]}
          >
            Confirm Pick
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp deck_builder_preview(assigns) do
    alias Oskol.Game.DeckBuilderCard

    card_name = DeckBuilderCard.card_name(assigns.deck_builder_card)
    card_description = DeckBuilderCard.card_description(assigns.deck_builder_card)

    # Check if we have the pending deck builder with 8 cards loaded
    has_preview =
      assigns[:pending_deck_builder] != nil and
        is_list(assigns.pending_deck_builder.available_cards) and
        length(assigns.pending_deck_builder.available_cards) == 8

    assigns =
      assigns
      |> assign(:card_name, card_name)
      |> assign(:card_description, card_description)
      |> assign(:has_preview, has_preview)

    ~H"""
    <div class="text-center bg-base-200/50 rounded-xl p-8 border-2 border-purple-500/30 max-w-4xl">
      <!-- Badge -->
      <div class="text-xs font-bold uppercase tracking-wide text-purple-500 mb-3">
        Deck Builder
      </div>
      
    <!-- Card Name -->
      <h3 class="text-4xl font-bold text-purple-500 mb-4">{@card_name}</h3>
      
    <!-- Description -->
      <div class="mb-6 px-4">
        <p class="text-base-content text-xl leading-relaxed">{@card_description}</p>
      </div>

      <%= if @has_preview do %>
        <!-- 8-Card Selection Grid -->
        <div class="mb-6">
          <div class="text-sm text-base-content/70 mb-4">
            Select a card to apply this enhancement (or skip):
            <%= if @deck_builder_selection do %>
              <span class="text-purple-500 font-bold ml-2">(Card selected)</span>
            <% end %>
          </div>
          <div class="grid grid-cols-4 gap-3 max-w-2xl mx-auto">
            <%= for card <- @pending_deck_builder.available_cards do %>
              <.deck_builder_card
                card={card}
                selected={@deck_builder_selection == card.id}
              />
            <% end %>
          </div>
        </div>
        
    <!-- Action Buttons -->
        <%= if @can_confirm do %>
          <div class="flex gap-4 justify-center">
            <button
              phx-click="skip_deck_builder_selection"
              class="px-8 py-3 rounded-lg bg-base-300 hover:bg-base-300/80 text-base-content transition-all font-semibold"
            >
              Skip
            </button>
            <%= if @deck_builder_selection do %>
              <button
                phx-click="confirm_deck_builder_pick"
                phx-value-card_id={@deck_builder_selection}
                disabled={@action_in_progress}
                class={[
                  "px-8 py-3 rounded-lg font-bold transition-all shadow-lg",
                  if(@action_in_progress,
                    do: "bg-purple-500/30 cursor-not-allowed opacity-50",
                    else: "bg-purple-500 hover:bg-purple-500/90 text-white hover:scale-[1.05]"
                  )
                ]}
              >
                Confirm Selection
              </button>
            <% end %>
          </div>
        <% end %>
      <% else %>
        <!-- Show "Confirm Pick" button before generating cards -->
        <%= if @can_confirm do %>
          <div class="flex justify-center mt-6">
            <button
              phx-click="confirm_deck_builder_preview"
              phx-value-index={@card_index}
              disabled={@action_in_progress}
              class={[
                "px-8 py-3 rounded-lg font-bold transition-all shadow-lg",
                if(@action_in_progress,
                  do: "bg-purple-500/30 cursor-not-allowed opacity-50",
                  else: "bg-purple-500 hover:bg-purple-500/90 text-white hover:scale-[1.05]"
                )
              ]}
            >
              Confirm Pick
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp deck_builder_card(assigns) do
    # Format card display
    rank_display =
      case assigns.card.rank do
        11 -> "J"
        12 -> "Q"
        13 -> "K"
        14 -> "A"
        n -> to_string(n)
      end

    suit_symbol =
      case assigns.card.suit do
        :hearts -> "♥"
        :diamonds -> "♦"
        :clubs -> "♣"
        :spades -> "♠"
      end

    suit_color =
      case assigns.card.suit do
        suit when suit in [:hearts, :diamonds] -> "text-error"
        _ -> "text-base-content"
      end

    # Check for enhancement
    enhancement_text =
      case assigns.card.enhancement do
        {:bonus_chips, amount} -> "+#{amount}c"
        {:bonus_mult, amount} -> "+#{amount}x"
        nil -> nil
      end

    border_class =
      if assigns.selected do
        "border-4 border-purple-500 scale-105"
      else
        "border-2 border-base-300 hover:border-purple-300"
      end

    assigns =
      assigns
      |> assign(:rank_display, rank_display)
      |> assign(:suit_symbol, suit_symbol)
      |> assign(:suit_color, suit_color)
      |> assign(:enhancement_text, enhancement_text)
      |> assign(:border_class, border_class)

    ~H"""
    <button
      phx-click="select_deck_card"
      phx-value-card_id={@card.id}
      class={[
        "aspect-[2/3] rounded-lg bg-base-100 flex flex-col items-center justify-center transition-all cursor-pointer hover:shadow-lg",
        @border_class
      ]}
    >
      <div class={"text-3xl font-bold #{@suit_color}"}>
        {@rank_display}
      </div>
      <div class={"text-4xl #{@suit_color}"}>
        {@suit_symbol}
      </div>
      <%= if @enhancement_text do %>
        <div class="mt-1 text-xs font-bold bg-purple-500/20 text-purple-500 px-2 py-0.5 rounded">
          {@enhancement_text}
        </div>
      <% end %>
    </button>
    """
  end
end
