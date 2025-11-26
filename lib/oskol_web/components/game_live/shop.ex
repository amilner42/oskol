defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components for the turn-based upgrade system.
  """
  use OskolWeb, :html

  def shop_screen(assigns) do
    ~H"""
    <div class="h-screen bg-gradient-to-br from-base-200 via-base-100 to-base-200">
      <!-- Main Shop: Two Column Layout -->
      <div class="h-full flex">
        <!-- Left Column: Card Grid -->
        <div class="w-[520px] border-r border-base-300/50 flex flex-col bg-base-100/50">
          <!-- Header -->
          <div class="p-6 border-b border-base-300/50">
            <div class="flex items-center justify-between">
              <div class="text-2xl font-light text-base-content">Shop</div>
              <.turn_indicator shop_state={@game_state.shop_state} player_id={@player_id} />
            </div>
          </div>

    <!-- Cards Grid: 3 columns x 5 rows -->
          <div class="flex-1 p-6 overflow-y-auto">
            <div class="grid grid-cols-3 gap-4">
              <%= for {shop_card, index} <- Enum.with_index(@game_state.shop_state.available_cards) do %>
                <.shop_card_minimal
                  shop_card={shop_card}
                  index={index}
                  is_picked={index in @game_state.shop_state.picked_card_indices}
                  is_selected={assigns[:previewing_card_index] == index}
                  can_pick={can_pick_card?(@game_state.shop_state, @player_id)}
                />
              <% end %>
            </div>
          </div>
        </div>

    <!-- Right Column: Preview Area -->
        <div class="flex-1 flex flex-col">
          <!-- Pick Status Bar -->
          <.pick_status_bar
            shop_state={@game_state.shop_state}
            player_id={@player_id}
            player_name={@player_name}
            opponent_name={@opponent_name}
            shop_countdown={assigns[:shop_countdown]}
          />

          <%= if assigns[:previewing_card_index] != nil do %>
            <.card_detail_panel
              shop_card={Enum.at(@game_state.shop_state.available_cards, @previewing_card_index)}
              card_index={@previewing_card_index}
              skill_tree={skill_tree_for_player(@player_id, assigns)}
              can_confirm={can_pick_card?(@game_state.shop_state, @player_id)}
              action_in_progress={@action_in_progress}
              pending_deck_builder={@game_state.shop_state.pending_deck_builder}
              deck_builder_selection={assigns[:deck_builder_selection]}
              pending_plus_bomb={@game_state.shop_state.pending_plus_bomb}
              plus_bomb_selection={assigns[:plus_bomb_selection]}
            />
          <% else %>
            <!-- Empty State -->
            <div class="flex-1 flex items-center justify-center">
              <div class="text-center">
                <%= if shop_complete?(@game_state.shop_state) do %>
                  <!-- Shop complete - show countdown -->
                  <.shop_countdown_display countdown={assigns[:shop_countdown]} />
                <% else %>
                  <%= if can_pick_card?(@game_state.shop_state, @player_id) do %>
                    <div class="w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center">
                      <svg
                        class="w-8 h-8 text-base-content/30"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="1.5"
                          d="M15 15l-2 5L9 9l11 4-5 2zm0 0l5 5M7.188 2.239l.777 2.897M5.136 7.965l-2.898-.777M13.95 4.05l-2.122 2.122m-5.657 5.656l-2.12 2.122"
                        />
                      </svg>
                    </div>
                    <p class="text-base-content/40 text-lg font-light">Select a card to preview</p>
                  <% else %>
                    <div class="w-16 h-16 rounded-full bg-base-300/50 mx-auto mb-4 flex items-center justify-center">
                      <svg
                        class="w-8 h-8 text-base-content/30 animate-pulse"
                        fill="none"
                        stroke="currentColor"
                        viewBox="0 0 24 24"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="1.5"
                          d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                        />
                      </svg>
                    </div>
                    <p class="text-base-content/40 text-lg font-light">Waiting for opponent...</p>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp shop_countdown_display(assigns) do
    ~H"""
    <div class="text-center">
      <div class="w-20 h-20 rounded-full bg-emerald-500/10 mx-auto mb-4 flex items-center justify-center">
        <span class="text-4xl font-light text-emerald-500">
          <%= if @countdown, do: @countdown, else: "5" %>
        </span>
      </div>
      <p class="text-base-content/60 text-lg font-light mb-2">All picks complete!</p>
      <p class="text-base-content/40 text-sm">Next round starting in...</p>
    </div>
    """
  end

  defp turn_indicator(assigns) do
    is_my_turn = can_pick_card?(assigns.shop_state, assigns.player_id)

    assigns = assign(assigns, :is_my_turn, is_my_turn)

    ~H"""
    <div class={[
      "px-3 py-1.5 rounded-full text-xs font-medium",
      if(@is_my_turn,
        do: "bg-emerald-500/10 text-emerald-600",
        else: "bg-base-300/50 text-base-content/40"
      )
    ]}>
      <%= if @is_my_turn do %>
        Your pick
      <% else %>
        Waiting
      <% end %>
    </div>
    """
  end

  defp pick_status_bar(assigns) do
    # Determine names based on picker IDs
    first_picker_name =
      if assigns.shop_state.first_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    second_picker_name =
      if assigns.shop_state.second_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    # Build list of all picks made so far
    # picked_card_indices is prepended (most recent first), so reverse it
    reversed_indices = Enum.reverse(assigns.shop_state.picked_card_indices)

    # Create a map of pick_number -> card for completed picks
    completed_picks =
      reversed_indices
      |> Enum.with_index()
      |> Enum.map(fn {card_idx, pick_num} ->
        {pick_num + 1, Enum.at(assigns.shop_state.available_cards, card_idx)}
      end)
      |> Map.new()

    # Total picks expected (2 per round)
    total_picks = assigns.shop_state.total_rounds * 2

    # Current pick number (1-indexed)
    current_pick_number = length(reversed_indices) + 1

    # Build all pick slots
    all_slots =
      for pick_num <- 1..total_picks do
        # Even picks (1, 3, 5...) are first picker, odd (2, 4, 6...) are second picker
        picker_name = if rem(pick_num, 2) == 1, do: first_picker_name, else: second_picker_name
        card = Map.get(completed_picks, pick_num)
        is_current = pick_num == current_pick_number and current_pick_number <= total_picks

        %{
          pick_number: pick_num,
          picker_name: picker_name,
          card: card,
          is_current: is_current,
          is_completed: card != nil
        }
      end

    is_my_turn = can_pick_card?(assigns.shop_state, assigns.player_id)
    all_complete = current_pick_number > total_picks

    assigns =
      assigns
      |> assign(:all_slots, all_slots)
      |> assign(:is_my_turn, is_my_turn)
      |> assign(:all_complete, all_complete)

    ~H"""
    <div class="p-6 border-b border-base-300/50">
      <!-- Current turn indicator -->
      <div class="mb-4">
        <%= if not @all_complete do %>
          <div class="flex items-center gap-2">
            <div class={[
              "w-2 h-2 rounded-full",
              if(@is_my_turn, do: "bg-emerald-500 animate-pulse", else: "bg-amber-500 animate-pulse")
            ]} />
            <span class="text-sm text-base-content/60">
              <%= if @is_my_turn do %>
                <span class="text-emerald-600 font-medium">Your turn</span> to pick
              <% else %>
                <% current_slot = Enum.find(@all_slots, & &1.is_current) %> Waiting for
                <span class="font-medium">{current_slot && current_slot.picker_name}</span>
              <% end %>
            </span>
          </div>
        <% else %>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-emerald-500" />
              <span class="text-sm text-emerald-600 font-medium">All picks complete</span>
            </div>
            <%= if @shop_countdown do %>
              <div class="flex items-center gap-2 text-sm text-base-content/60">
                <span>Next round in</span>
                <span class="font-mono text-emerald-500 font-medium">{@shop_countdown}s</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

    <!-- All pick slots - evenly spaced -->
      <div class="flex gap-3">
        <%= for slot <- @all_slots do %>
          <.pick_slot_compact
            pick_card={slot.card}
            picker_name={slot.picker_name}
            pick_number={slot.pick_number}
            is_current={slot.is_current}
            is_completed={slot.is_completed}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp pick_slot_compact(assigns) do
    alias Oskol.Game.{DeckBuilderCard, ActionCard}

    card_display =
      case assigns[:pick_card] do
        {:level_up, hand_type} ->
          %{type: :level_up, name: format_hand_name(hand_type), color: "emerald"}

        {:action, action_card} ->
          # Use amber for scrambler, rose for others
          color = if action_card.type == :scrambler, do: "amber", else: "rose"
          %{type: :action, name: ActionCard.card_name(action_card), color: color}

        {:deck_builder, deck_builder_card} ->
          %{
            type: :deck_builder,
            name: DeckBuilderCard.card_name(deck_builder_card),
            color: "violet"
          }

        nil ->
          nil
      end

    ordinal =
      case assigns.pick_number do
        1 -> "1st"
        2 -> "2nd"
        3 -> "3rd"
        n -> "#{n}th"
      end

    assigns =
      assigns
      |> assign(:card_display, card_display)
      |> assign(:ordinal, ordinal)

    ~H"""
    <div class={[
      "flex-1 rounded-lg p-3 border transition-all",
      cond do
        @card_display != nil -> "bg-base-100 border-base-300/50"
        @is_current -> "bg-base-200/50 border-dashed border-emerald-400 animate-pulse"
        true -> "bg-base-200/30 border-base-300/30"
      end
    ]}>
      <div class="text-[10px] uppercase tracking-wider text-base-content/40 mb-1">{@ordinal}</div>
      <%= if @card_display do %>
        <div class="flex items-center gap-2">
          <div class={[
            "w-2 h-2 rounded-full flex-shrink-0",
            case @card_display.color do
              "emerald" -> "bg-emerald-500"
              "rose" -> "bg-rose-500"
              "violet" -> "bg-violet-500"
              "amber" -> "bg-amber-500"
            end
          ]} />
          <div class="min-w-0">
            <div class="text-sm font-medium text-base-content truncate">{@card_display.name}</div>
            <div class="text-[10px] text-base-content/40">{@picker_name}</div>
          </div>
        </div>
      <% else %>
        <div class="text-sm text-base-content/30">{@picker_name}</div>
      <% end %>
    </div>
    """
  end

  defp skill_tree_for_player(player_id, assigns) do
    # Extract skill tree from game state for the given player
    player_state = assigns.game_state.players[player_id]
    player_state && player_state.skill_tree
  end

  defp shop_card_minimal(assigns) do
    alias Oskol.Game.{DeckBuilderCard, ActionCard}

    {card_type, action_subtype, display_name, accent_color} =
      case assigns.shop_card do
        {:level_up, hand_type} ->
          {:level_up, nil, format_hand_name(hand_type), "emerald"}

        {:action, action_card} ->
          subtype =
            case action_card.type do
              :denial -> :blocker
              :scrambler -> :scrambler
              :plus_bomb -> :plus_bomb
              :static -> :static
            end

          color = if action_card.type == :scrambler, do: "amber", else: "rose"
          {:action, subtype, ActionCard.card_name(action_card), color}

        {:deck_builder, deck_builder_card} ->
          {:deck_builder, nil, DeckBuilderCard.card_name(deck_builder_card), "violet"}
      end

    # Use different events for deck builders and plus_bomb vs other cards
    click_event =
      if assigns[:can_pick] and not assigns[:is_picked] do
        case assigns.shop_card do
          {:deck_builder, _} -> "preview_deck_builder"
          {:action, %{type: :plus_bomb}} -> "preview_plus_bomb"
          _ -> "preview_shop_card"
        end
      else
        nil
      end

    assigns =
      assigns
      |> assign(:card_type, card_type)
      |> assign(:action_subtype, action_subtype)
      |> assign(:display_name, display_name)
      |> assign(:accent_color, accent_color)
      |> assign(:click_event, click_event)

    ~H"""
    <button
      phx-click={@click_event}
      phx-value-index={@index}
      disabled={@is_picked or not @can_pick}
      class={[
        "aspect-[2/3] rounded-xl p-4 flex flex-col transition-all relative overflow-hidden",
        "bg-base-100 border-2",
        cond do
          @is_picked ->
            "opacity-30 cursor-not-allowed border-base-300/30"

          @is_selected ->
            case @accent_color do
              "emerald" -> "border-emerald-500 shadow-lg shadow-emerald-500/20 scale-[1.02]"
              "rose" -> "border-rose-500 shadow-lg shadow-rose-500/20 scale-[1.02]"
              "violet" -> "border-violet-500 shadow-lg shadow-violet-500/20 scale-[1.02]"
              "amber" -> "border-amber-500 shadow-lg shadow-amber-500/20 scale-[1.02]"
            end

          @can_pick ->
            case @accent_color do
              "emerald" ->
                "border-base-300/50 hover:border-emerald-400 hover:shadow-md cursor-pointer"

              "rose" ->
                "border-base-300/50 hover:border-rose-400 hover:shadow-md cursor-pointer"

              "violet" ->
                "border-base-300/50 hover:border-violet-400 hover:shadow-md cursor-pointer"

              "amber" ->
                "border-base-300/50 hover:border-amber-400 hover:shadow-md cursor-pointer"
            end

          true ->
            "border-base-300/30 cursor-not-allowed"
        end
      ]}
    >
      <!-- Type badge at top -->
      <div class={[
        "text-[10px] font-bold uppercase tracking-wider mb-2",
        case @accent_color do
          "emerald" -> "text-emerald-500"
          "rose" -> "text-rose-500"
          "violet" -> "text-violet-500"
          "amber" -> "text-amber-500"
        end
      ]}>
        <%= case @card_type do %>
          <% :level_up -> %>
            Level Up
          <% :action -> %>
            <%= case @action_subtype do %>
              <% :scrambler -> %>
                Scrambler
              <% :plus_bomb -> %>
                Action
              <% :static -> %>
                Action
              <% _ -> %>
                Blocker
            <% end %>
          <% :deck_builder -> %>
            Deck Builder
        <% end %>
      </div>

    <!-- Card name centered -->
      <div class="flex-1 flex items-center justify-center">
        <div class={[
          "font-semibold text-sm text-center leading-tight",
          if(@is_picked, do: "text-base-content/30", else: "text-base-content")
        ]}>
          {@display_name}
        </div>
      </div>

      <%= if @is_picked do %>
        <div class="absolute inset-0 bg-base-100/80 flex items-center justify-center rounded-xl">
          <div class="flex flex-col items-center gap-1">
            <svg
              class="w-6 h-6 text-base-content/40"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 13l4 4L19 7"
              />
            </svg>
            <span class="text-xs text-base-content/40 font-medium">Picked</span>
          </div>
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

  defp card_detail_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col">
      <%= case @shop_card do %>
        <% {:level_up, hand_type} -> %>
          <.level_up_detail
            hand_type={hand_type}
            skill_tree={@skill_tree}
            can_confirm={@can_confirm}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
          />
        <% {:action, action_card} -> %>
          <.action_detail
            action_card={action_card}
            can_confirm={@can_confirm}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
            pending_plus_bomb={@pending_plus_bomb}
            plus_bomb_selection={@plus_bomb_selection}
          />
        <% {:deck_builder, deck_builder_card} -> %>
          <.deck_builder_detail
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

  defp level_up_detail(assigns) do
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
    <div class="flex-1 flex flex-col p-8">
      <!-- Header -->
      <div class="mb-8">
        <div class="text-xs uppercase tracking-widest text-emerald-500/60 mb-1">Level Up</div>
        <h2 class="text-4xl font-light text-base-content">{@hand_name}</h2>
      </div>

    <!-- Level indicator -->
      <div class="mb-12">
        <div class="flex items-center gap-4">
          <div class="flex items-center gap-2">
            <span class="text-3xl font-light text-base-content/40">{@current_level}</span>
            <svg
              class="w-5 h-5 text-emerald-500"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 7l5 5m0 0l-5 5m5-5H6"
              />
            </svg>
            <span class="text-3xl font-medium text-emerald-500">{@next_level}</span>
          </div>
        </div>
      </div>

    <!-- Stats -->
      <div class="space-y-6 flex-1">
        <div class="flex items-baseline justify-between border-b border-base-300/30 pb-4">
          <span class="text-base-content/50 text-sm uppercase tracking-wider">Base Chips</span>
          <div class="flex items-center gap-3">
            <span class="text-base-content/30 text-lg">{@current_stats.base_chips}</span>
            <svg
              class="w-4 h-4 text-base-content/20"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M17 8l4 4m0 0l-4 4m4-4H3"
              />
            </svg>
            <span class="text-emerald-500 text-2xl font-medium">{@next_stats.base_chips}</span>
          </div>
        </div>
        <div class="flex items-baseline justify-between border-b border-base-300/30 pb-4">
          <span class="text-base-content/50 text-sm uppercase tracking-wider">Multiplier</span>
          <div class="flex items-center gap-3">
            <span class="text-base-content/30 text-lg">{@current_stats.multiplier}x</span>
            <svg
              class="w-4 h-4 text-base-content/20"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M17 8l4 4m0 0l-4 4m4-4H3"
              />
            </svg>
            <span class="text-emerald-500 text-2xl font-medium">{@next_stats.multiplier}x</span>
          </div>
        </div>
      </div>

    <!-- Action Button -->
      <%= if @can_confirm do %>
        <div class="pt-8">
          <button
            phx-click="confirm_shop_pick"
            phx-value-index={@card_index}
            disabled={@action_in_progress}
            class={[
              "w-full py-4 rounded-full font-medium text-lg transition-all",
              if(@action_in_progress,
                do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                else: "bg-emerald-500 text-white hover:bg-emerald-600 shadow-lg hover:shadow-xl"
              )
            ]}
          >
            Confirm Selection
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp action_detail(assigns) do
    card_name = Oskol.Game.ActionCard.card_name(assigns.action_card)
    card_description = Oskol.Game.ActionCard.card_description(assigns.action_card)
    action_type = assigns.action_card.type
    is_scrambler = action_type == :scrambler
    requires_selection = Oskol.Game.ActionCard.requires_selection?(assigns.action_card)

    # For denial cards, show the target hand
    hand_name =
      if assigns.action_card.target_hand do
        format_hand_name(assigns.action_card.target_hand)
      else
        nil
      end

    # Use amber for scrambler, rose for others
    accent_color = if is_scrambler, do: "amber", else: "rose"

    type_label =
      case action_type do
        :scrambler -> "Scrambler"
        :plus_bomb -> "Action"
        :static -> "Action"
        :denial -> "Blocker"
      end

    # Check if we have pending plus bomb selection
    has_plus_bomb_preview =
      assigns[:pending_plus_bomb] != nil and
        is_list(assigns.pending_plus_bomb.available_cards) and
        length(assigns.pending_plus_bomb.available_cards) == 8

    assigns =
      assigns
      |> assign(:card_name, card_name)
      |> assign(:card_description, card_description)
      |> assign(:hand_name, hand_name)
      |> assign(:is_scrambler, is_scrambler)
      |> assign(:accent_color, accent_color)
      |> assign(:type_label, type_label)
      |> assign(:action_type, action_type)
      |> assign(:requires_selection, requires_selection)
      |> assign(:has_plus_bomb_preview, has_plus_bomb_preview)

    ~H"""
    <div class="flex-1 flex flex-col p-8">
      <!-- Header -->
      <div class="mb-8">
        <div class={[
          "text-xs uppercase tracking-widest mb-1",
          if(@accent_color == "amber", do: "text-amber-500/60", else: "text-rose-500/60")
        ]}>
          {@type_label}
        </div>
        <h2 class="text-4xl font-light text-base-content">{@card_name}</h2>
      </div>

      <%= if @hand_name do %>
        <!-- Target for denial cards -->
        <div class="mb-8">
          <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-rose-500/10">
            <svg class="w-4 h-4 text-rose-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
              />
            </svg>
            <span class="text-rose-500 font-medium">{@hand_name}</span>
          </div>
        </div>
      <% end %>

      <%= if @is_scrambler do %>
        <!-- Scrambler effect indicator -->
        <div class="mb-8">
          <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-amber-500/10">
            <svg class="w-4 h-4 text-amber-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
            <span class="text-amber-500 font-medium">1-in-4 face-down</span>
          </div>
        </div>
      <% end %>

      <!-- Description -->
      <div class="mb-8">
        <p class="text-base-content/60 text-lg leading-relaxed">{@card_description}</p>
      </div>

      <%= if @has_plus_bomb_preview do %>
        <!-- Plus Bomb card selection -->
        <div class="mb-4">
          <div class="flex items-center justify-between">
            <span class="text-sm text-base-content/50">Select a card - that rank AND suit won't score for opponent</span>
            <%= if @plus_bomb_selection do %>
              <span class="text-xs px-2 py-1 rounded-full bg-rose-500/10 text-rose-500">
                1 selected
              </span>
            <% end %>
          </div>
        </div>

        <!-- 8-Card Selection Grid for Plus Bomb -->
        <div class="flex-1 mb-6">
          <div class="grid grid-cols-4 gap-3">
            <%= for card <- @pending_plus_bomb.available_cards do %>
              <% is_selected = @plus_bomb_selection == card.id %>
              <.plus_bomb_card_minimal
                card={card}
                selected={is_selected}
              />
            <% end %>
          </div>
        </div>

        <!-- Confirm Button for Plus Bomb -->
        <%= if @can_confirm and @plus_bomb_selection do %>
          <div class="pt-4">
            <button
              phx-click="confirm_plus_bomb_pick"
              phx-value-card_id={@plus_bomb_selection}
              disabled={@action_in_progress}
              class={[
                "w-full py-4 rounded-full font-medium text-lg transition-all",
                if(@action_in_progress,
                  do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                  else: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg hover:shadow-xl"
                )
              ]}
            >
              Confirm Selection
            </button>
          </div>
        <% end %>
      <% else %>
        <!-- Flex spacer -->
        <div class="flex-1"></div>

        <!-- Action Button -->
        <%= if @can_confirm do %>
          <div class="pt-8">
            <%= if @requires_selection do %>
              <!-- Plus Bomb needs two-phase: first choose the card, then select from 8 -->
              <button
                phx-click="confirm_plus_bomb_preview"
                phx-value-index={@card_index}
                disabled={@action_in_progress}
                class={[
                  "w-full py-4 rounded-full font-medium text-lg transition-all",
                  if(@action_in_progress,
                    do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                    else: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg hover:shadow-xl"
                  )
                ]}
              >
                Choose Card
              </button>
            <% else %>
              <!-- Static, Denial, and Scrambler - immediate effect -->
              <button
                phx-click="confirm_shop_pick"
                phx-value-index={@card_index}
                disabled={@action_in_progress}
                class={[
                  "w-full py-4 rounded-full font-medium text-lg transition-all",
                  if(@action_in_progress,
                    do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                    else:
                      if(@accent_color == "amber",
                        do: "bg-amber-500 text-white hover:bg-amber-600 shadow-lg hover:shadow-xl",
                        else: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg hover:shadow-xl"
                      )
                  )
                ]}
              >
                Confirm Selection
              </button>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp plus_bomb_card_minimal(assigns) do
    alias OskolWeb.Components.GameLive.Gameplay

    ~H"""
    <button
      phx-click="select_plus_bomb_card"
      phx-value-card_id={@card.id}
      class={[
        "transition-all cursor-pointer rounded-lg overflow-hidden",
        if(@selected,
          do: "ring-2 ring-rose-500 ring-offset-2 ring-offset-base-100 scale-105 shadow-lg",
          else: "hover:shadow-md hover:scale-102 border border-base-300/50"
        )
      ]}
    >
      <Gameplay.card_display card={@card} class="w-full aspect-[2/3]" />
    </button>
    """
  end

  defp deck_builder_detail(assigns) do
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
    <div class="flex-1 flex flex-col p-8">
      <!-- Header -->
      <div class="mb-6">
        <div class="text-xs uppercase tracking-widest text-violet-500/60 mb-1">Deck Builder</div>
        <h2 class="text-4xl font-light text-base-content">{@card_name}</h2>
      </div>

    <!-- Description -->
      <div class="mb-8">
        <p class="text-base-content/60 text-lg leading-relaxed">{@card_description}</p>
      </div>

      <%= if @has_preview do %>
        <!-- Selection instruction -->
        <div class="mb-4">
          <% card_type = @pending_deck_builder.deck_builder_card.type

          instruction =
            case card_type do
              :remove_card ->
                "Select up to 2 cards to remove"

              type
              when type in [
                     :change_suit_hearts,
                     :change_suit_diamonds,
                     :change_suit_clubs,
                     :change_suit_spades
                   ] ->
                "Select up to 3 cards to change"

              :increase_rank ->
                "Select up to 2 cards to upgrade"

              _ ->
                "Select a card to enhance"
            end %>
          <div class="flex items-center justify-between">
            <span class="text-sm text-base-content/50">{instruction}</span>
            <%= if @deck_builder_selection do %>
              <% count =
                if is_list(@deck_builder_selection) do
                  length(@deck_builder_selection)
                else
                  1
                end %>
              <span class="text-xs px-2 py-1 rounded-full bg-violet-500/10 text-violet-500">
                {count} selected
              </span>
            <% end %>
          </div>
        </div>

    <!-- 8-Card Selection Grid -->
        <div class="flex-1 mb-6">
          <div class="grid grid-cols-4 gap-3">
            <%= for card <- @pending_deck_builder.available_cards do %>
              <% is_selected =
                if is_list(@deck_builder_selection) do
                  card.id in @deck_builder_selection
                else
                  @deck_builder_selection == card.id
                end %>
              <.deck_builder_card_minimal
                card={card}
                selected={is_selected}
              />
            <% end %>
          </div>
        </div>

    <!-- Action Buttons -->
        <%= if @can_confirm do %>
          <div class="flex gap-3">
            <button
              phx-click="skip_deck_builder_selection"
              class="flex-1 py-4 rounded-full font-medium text-base-content/60 bg-base-300/50 hover:bg-base-300 transition-all"
            >
              Skip
            </button>
            <%= if @deck_builder_selection do %>
              <% card_ids_param =
                if is_list(@deck_builder_selection) do
                  Jason.encode!(@deck_builder_selection)
                else
                  @deck_builder_selection
                end %>
              <button
                phx-click="confirm_deck_builder_pick"
                phx-value-card_ids={card_ids_param}
                disabled={@action_in_progress}
                class={[
                  "flex-1 py-4 rounded-full font-medium text-lg transition-all",
                  if(@action_in_progress,
                    do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                    else: "bg-violet-500 text-white hover:bg-violet-600 shadow-lg hover:shadow-xl"
                  )
                ]}
              >
                Confirm
              </button>
            <% end %>
          </div>
        <% end %>
      <% else %>
        <!-- Initial confirm button -->
        <%= if @can_confirm do %>
          <div class="flex-1 flex items-end">
            <button
              phx-click="confirm_deck_builder_preview"
              phx-value-index={@card_index}
              disabled={@action_in_progress}
              class={[
                "w-full py-4 rounded-full font-medium text-lg transition-all",
                if(@action_in_progress,
                  do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                  else: "bg-violet-500 text-white hover:bg-violet-600 shadow-lg hover:shadow-xl"
                )
              ]}
            >
              Choose Cards
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp deck_builder_card_minimal(assigns) do
    alias OskolWeb.Components.GameLive.Gameplay

    ~H"""
    <button
      phx-click="select_deck_card"
      phx-value-card_id={@card.id}
      class={[
        "transition-all cursor-pointer rounded-lg overflow-hidden",
        if(@selected,
          do: "ring-2 ring-violet-500 ring-offset-2 ring-offset-base-100 scale-105 shadow-lg",
          else: "hover:shadow-md hover:scale-102 border border-base-300/50"
        )
      ]}
    >
      <Gameplay.card_display card={@card} class="w-full aspect-[2/3]" />
    </button>
    """
  end
end
