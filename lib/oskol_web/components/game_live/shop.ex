defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components for the turn-based upgrade system.
  """
  use OskolWeb, :html

  alias Oskol.Game.{ShopCard, ShopState}
  alias OskolWeb.Utils.Format

  def shop_screen(assigns) do
    # Pre-compute shared values
    has_pending_selection =
      has_pending_selection?(assigns.game_state.shop_state, assigns.player_id)

    in_destroy_phase = ShopState.in_destroy_phase?(assigns.game_state.shop_state)
    can_destroy = ShopState.can_destroy?(assigns.game_state.shop_state, assigns.player_id)
    can_pick = can_pick_card?(assigns.game_state.shop_state, assigns.player_id)
    is_active_player = if in_destroy_phase, do: can_destroy, else: can_pick

    # Build map of card_index -> picker_name
    first_picker_name =
      if assigns.game_state.shop_state.first_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    second_picker_name =
      if assigns.game_state.shop_state.second_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    reversed_indices = Enum.reverse(assigns.game_state.shop_state.picked_card_indices)

    picked_by_map =
      reversed_indices
      |> Enum.with_index()
      |> Enum.map(fn {card_idx, pick_num} ->
        picker_name = if rem(pick_num, 2) == 0, do: first_picker_name, else: second_picker_name
        {card_idx, picker_name}
      end)
      |> Map.new()

    assigns =
      assigns
      |> assign(:has_pending_selection, has_pending_selection)
      |> assign(:in_destroy_phase, in_destroy_phase)
      |> assign(:can_destroy, can_destroy)
      |> assign(:can_pick, can_pick)
      |> assign(:is_active_player, is_active_player)
      |> assign(:picked_by_map, picked_by_map)

    ~H"""
    <div class="h-screen-safe bg-gradient-to-br from-base-200 via-base-100 to-base-200 overflow-auto">
      <!-- Responsive layout using CSS order -->
      <div class="min-h-full flex flex-col lg:flex-row lg:h-screen">

    <!-- Section 1: Header (order-1 on mobile, part of left column on desktop) -->
        <div class="order-1 lg:order-none lg:w-[440px] xl:w-[540px] lg:flex-shrink-0 lg:border-r border-base-300/50 bg-base-100/50 lg:flex lg:flex-col lg:h-screen">
          <!-- Header -->
          <div class="p-6 border-b border-base-300/50 flex-shrink-0">
            <div class="flex items-center justify-between mb-4">
              <div class="text-2xl font-light text-base-content">Command Center</div>
              <.turn_indicator shop_state={@game_state.shop_state} player_id={@player_id} />
            </div>
            <!-- Round and Lives Status -->
            <.game_status_bar
              game_state={@game_state}
              player_state={@player_state}
              opponent_state={@opponent_state}
              player_name={@player_name}
              opponent_name={@opponent_name}
            />
          </div>
          
    <!-- Cards Grid (hidden on mobile, shown on desktop) -->
          <div class="hidden lg:block flex-1 p-6">
            <.shop_cards_grid
              game_state={@game_state}
              player_id={@player_id}
              previewing_card_index={assigns[:previewing_card_index]}
              has_pending_selection={@has_pending_selection}
              in_destroy_phase={@in_destroy_phase}
              can_destroy={@can_destroy}
              picked_by_map={@picked_by_map}
            />
          </div>
        </div>
        
    <!-- Section 2: Timeline (order-2 on mobile) -->
        <div class="order-2 lg:order-none lg:flex-1 lg:flex lg:flex-col lg:h-screen lg:overflow-hidden">
          <div class="flex-shrink-0">
            <.pick_status_bar
              shop_state={@game_state.shop_state}
              player_id={@player_id}
              player_name={@player_name}
              opponent_name={@opponent_name}
              shop_countdown={assigns[:shop_countdown]}
            />
          </div>
          
    <!-- Preview Panel (hidden on mobile, shown on desktop) -->
          <div class="hidden lg:flex flex-1 flex-col overflow-hidden">
            <.preview_panel
              game_state={@game_state}
              player_id={@player_id}
              previewing_card_index={assigns[:previewing_card_index]}
              is_active_player={@is_active_player}
              in_destroy_phase={@in_destroy_phase}
              action_in_progress={@action_in_progress}
              deck_builder_selection={assigns[:deck_builder_selection]}
              plus_bomb_selection={assigns[:plus_bomb_selection]}
              shop_countdown={assigns[:shop_countdown]}
            />
          </div>
        </div>
        
    <!-- Section 3: Cards (order-3 on mobile only, horizontal scroll) -->
        <div class="order-3 lg:hidden px-3 py-3 border-t border-base-300/50 bg-base-100/50">
          <div class="flex gap-2 overflow-x-auto pb-2 pt-1">
            <%= for {shop_card, index} <- Enum.with_index(@game_state.shop_state.available_cards) do %>
              <.shop_card_minimal
                shop_card={shop_card}
                index={index}
                is_picked={index in @game_state.shop_state.picked_card_indices}
                picked_by={Map.get(@picked_by_map, index)}
                is_destroyed={index in @game_state.shop_state.destroyed_card_indices}
                is_selected={assigns[:previewing_card_index] == index}
                can_pick={
                  can_pick_card?(@game_state.shop_state, @player_id) and not @has_pending_selection
                }
                in_destroy_phase={@in_destroy_phase}
                can_destroy={@can_destroy}
              />
            <% end %>
          </div>
        </div>
        
    <!-- Section 4: Preview (order-4 on mobile only) -->
        <div class="order-4 lg:hidden flex-1 flex flex-col">
          <.preview_panel
            game_state={@game_state}
            player_id={@player_id}
            previewing_card_index={assigns[:previewing_card_index]}
            is_active_player={@is_active_player}
            in_destroy_phase={@in_destroy_phase}
            action_in_progress={@action_in_progress}
            deck_builder_selection={assigns[:deck_builder_selection]}
            plus_bomb_selection={assigns[:plus_bomb_selection]}
            shop_countdown={assigns[:shop_countdown]}
          />
        </div>
      </div>
    </div>
    """
  end

  defp shop_cards_grid(assigns) do
    ~H"""
    <!-- Arsenal Section (Permanent Upgrades) -->
    <div class="mb-6">
      <div class="mb-3 flex items-center gap-2">
        <div class="text-sm font-semibold uppercase tracking-wider text-base-content/40">
          Arsenal
        </div>
        <div class="text-xs text-base-content/40">Permanent Upgrades</div>
      </div>
      <div class="grid grid-cols-4 gap-3">
        <%= for {shop_card, index} <- Enum.with_index(@game_state.shop_state.available_cards) |> Enum.take(8) do %>
          <.shop_card_minimal
            shop_card={shop_card}
            index={index}
            is_picked={index in @game_state.shop_state.picked_card_indices}
            picked_by={Map.get(@picked_by_map, index)}
            is_destroyed={index in @game_state.shop_state.destroyed_card_indices}
            is_selected={@previewing_card_index == index}
            can_pick={
              can_pick_card?(@game_state.shop_state, @player_id) and not @has_pending_selection
            }
            in_destroy_phase={@in_destroy_phase}
            can_destroy={@can_destroy}
          />
        <% end %>
      </div>
    </div>

    <!-- Tactical Ops Section (Action Cards) -->
    <div>
      <div class="mb-3 flex items-center gap-2">
        <div class="text-sm font-semibold uppercase tracking-wider text-base-content/40">
          Tactical Ops
        </div>
        <div class="text-xs text-base-content/40">Temporary Battlefield Advantage</div>
      </div>
      <div class="grid grid-cols-4 gap-3">
        <%= for {shop_card, index} <- Enum.with_index(@game_state.shop_state.available_cards) |> Enum.drop(8) do %>
          <.shop_card_minimal
            shop_card={shop_card}
            index={index}
            is_picked={index in @game_state.shop_state.picked_card_indices}
            picked_by={Map.get(@picked_by_map, index)}
            is_destroyed={index in @game_state.shop_state.destroyed_card_indices}
            is_selected={@previewing_card_index == index}
            can_pick={
              can_pick_card?(@game_state.shop_state, @player_id) and not @has_pending_selection
            }
            in_destroy_phase={@in_destroy_phase}
            can_destroy={@can_destroy}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp preview_panel(assigns) do
    ~H"""
    <%= if @previewing_card_index != nil do %>
      <!-- Card preview (works in both normal and destroy phase) -->
      <.card_detail_panel
        shop_card={Enum.at(@game_state.shop_state.available_cards, @previewing_card_index)}
        card_index={@previewing_card_index}
        skill_tree={skill_tree_for_player(@player_id, assigns)}
        is_active_player={@is_active_player}
        in_destroy_phase={@in_destroy_phase}
        action_in_progress={@action_in_progress}
        pending_deck_builder={@game_state.shop_state.pending_deck_builder}
        deck_builder_selection={@deck_builder_selection}
        pending_plus_bomb={@game_state.shop_state.pending_plus_bomb}
        plus_bomb_selection={@plus_bomb_selection}
      />
    <% else %>
      <%= if ShopState.in_destroy_phase?(@game_state.shop_state) do %>
        <!-- Destroy Phase Panel (when no card is selected) -->
        <.destroy_phase_panel
          shop_state={@game_state.shop_state}
          player_id={@player_id}
          action_in_progress={@action_in_progress}
        />
      <% else %>
        <!-- Empty State -->
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center">
            <%= if shop_complete?(@game_state.shop_state) do %>
              <!-- Shop complete - show countdown -->
              <.shop_countdown_display countdown={@shop_countdown} />
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
    <% end %>
    """
  end

  defp shop_countdown_display(assigns) do
    ~H"""
    <div class="text-center">
      <div class="w-20 h-20 rounded-full bg-emerald-500/10 mx-auto mb-4 flex items-center justify-center">
        <span class="text-4xl font-light text-emerald-500">
          {if @countdown, do: @countdown, else: "5"}
        </span>
      </div>
      <p class="text-base-content/60 text-lg font-light mb-2">All picks complete!</p>
      <p class="text-base-content/40 text-sm">Next round starting in...</p>
    </div>
    """
  end

  defp destroy_phase_panel(assigns) do
    shop_state = assigns.shop_state
    can_destroy = ShopState.can_destroy?(shop_state, assigns.player_id)
    destroys_remaining = ShopState.destroys_remaining(shop_state)
    destroys_used = length(shop_state.destroyed_card_indices)

    assigns =
      assigns
      |> assign(:can_destroy, can_destroy)
      |> assign(:destroys_remaining, destroys_remaining)
      |> assign(:destroys_used, destroys_used)
      |> assign(:destroys_allowed, shop_state.destroys_allowed)

    ~H"""
    <div class="flex-1 flex flex-col p-8">
      <%= if @can_destroy do %>
        <!-- Destroyer's view -->
        <div class="mb-8">
          <div class="text-xs uppercase tracking-widest text-rose-500/60 mb-1">Destroy Phase</div>
          <h2 class="text-4xl font-light text-base-content">Remove Cards</h2>
        </div>

        <div class="mb-8">
          <p class="text-base-content/60 text-lg leading-relaxed mb-4">
            You're behind in lives. Select cards to destroy and deny them from both players.
          </p>
          <div class="inline-flex items-center gap-3 px-4 py-3 rounded-xl bg-rose-500/10">
            <div class="text-rose-500">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <div>
              <div class="text-rose-600 font-medium">{@destroys_remaining} destroys remaining</div>
              <div class="text-rose-500/60 text-sm">{@destroys_used} of {@destroys_allowed} used</div>
            </div>
          </div>
        </div>

        <div class="flex-1"></div>

        <div class="pt-8">
          <button
            phx-click="complete_destroy_phase"
            disabled={@action_in_progress}
            class={[
              "w-full py-4 rounded-full font-medium text-lg transition-all",
              if(@action_in_progress,
                do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                else: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg hover:shadow-xl"
              )
            ]}
          >
            <%= if @destroys_remaining > 0 do %>
              Done (skip remaining)
            <% else %>
              Continue to Picks
            <% end %>
          </button>
        </div>
      <% else %>
        <!-- Waiting player's view -->
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center">
            <div class="w-16 h-16 rounded-full bg-rose-500/10 mx-auto mb-4 flex items-center justify-center">
              <svg
                class="w-8 h-8 text-rose-400 animate-pulse"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <p class="text-base-content/60 text-lg font-light mb-2">Opponent is destroying cards</p>
            <p class="text-base-content/40 text-sm">{@destroys_remaining} destroys remaining</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp turn_indicator(assigns) do
    in_destroy_phase = ShopState.in_destroy_phase?(assigns.shop_state)
    can_destroy = ShopState.can_destroy?(assigns.shop_state, assigns.player_id)
    is_my_turn = can_pick_card?(assigns.shop_state, assigns.player_id)

    assigns =
      assigns
      |> assign(:in_destroy_phase, in_destroy_phase)
      |> assign(:can_destroy, can_destroy)
      |> assign(:is_my_turn, is_my_turn)

    ~H"""
    <div class={[
      "px-3 py-1.5 rounded-full text-xs font-medium",
      cond do
        @in_destroy_phase and @can_destroy -> "bg-rose-500/10 text-rose-600"
        @in_destroy_phase -> "bg-base-300/50 text-base-content/40"
        @is_my_turn -> "bg-emerald-500/10 text-emerald-600"
        true -> "bg-base-300/50 text-base-content/40"
      end
    ]}>
      <%= cond do %>
        <% @in_destroy_phase and @can_destroy -> %>
          Destroy
        <% @in_destroy_phase -> %>
          Waiting
        <% @is_my_turn -> %>
          Your pick
        <% true -> %>
          Waiting
      <% end %>
    </div>
    """
  end

  defp game_status_bar(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-6">
      <!-- Round indicator -->
      <div class="flex items-center gap-2">
        <div class="text-xs uppercase tracking-wider text-base-content/40">Round</div>
        <div class="text-lg font-semibold text-base-content">{@game_state.round_number}</div>
      </div>

      <!-- Divider (hidden on mobile) -->
      <div class="hidden sm:block w-px h-6 bg-base-300/50"></div>

      <!-- Lives status -->
      <div class="flex items-center gap-4">
        <!-- Player lives -->
        <div class="flex items-center gap-2">
          <span class="text-xs text-player font-medium">{@player_name}</span>
          <div class="flex items-center gap-0.5">
            <%= for i <- 1..@game_state.initial_lives do %>
              <%= if i <= @player_state.lives do %>
                <.icon name="hero-heart-solid" class="w-4 h-4 text-error" />
              <% else %>
                <.icon name="hero-heart" class="w-4 h-4 text-base-content/20" />
              <% end %>
            <% end %>
          </div>
        </div>

        <!-- VS divider -->
        <span class="text-xs text-base-content/30">vs</span>

        <!-- Opponent lives -->
        <div class="flex items-center gap-2">
          <span class="text-xs text-opponent font-medium">{@opponent_name}</span>
          <div class="flex items-center gap-0.5">
            <%= for i <- 1..@game_state.initial_lives do %>
              <%= if i <= @opponent_state.lives do %>
                <.icon name="hero-heart-solid" class="w-4 h-4 text-error" />
              <% else %>
                <.icon name="hero-heart" class="w-4 h-4 text-base-content/20" />
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp pick_status_bar(assigns) do
    shop_state = assigns.shop_state
    in_destroy_phase = ShopState.in_destroy_phase?(shop_state)

    # Determine names based on picker IDs
    first_picker_name =
      if shop_state.first_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    second_picker_name =
      if shop_state.second_picker_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    destroyer_name =
      if shop_state.destroyer_id == assigns.player_id,
        do: assigns.player_name,
        else: assigns.opponent_name

    # Build destroy slots (if any)
    destroys_allowed = shop_state.destroys_allowed
    reversed_destroyed = Enum.reverse(shop_state.destroyed_card_indices)
    destroys_completed = length(reversed_destroyed)
    current_destroy_number = destroys_completed + 1

    destroy_slots =
      if destroys_allowed > 0 do
        for destroy_num <- 1..destroys_allowed do
          card_idx = Enum.at(reversed_destroyed, destroy_num - 1)
          card = if card_idx, do: Enum.at(shop_state.available_cards, card_idx), else: nil

          is_current =
            in_destroy_phase and destroy_num == current_destroy_number and
              current_destroy_number <= destroys_allowed

          %{
            type: :destroy,
            slot_number: destroy_num,
            picker_name: destroyer_name,
            card: card,
            is_current: is_current,
            is_completed: card != nil
          }
        end
      else
        []
      end

    # Build list of all picks made so far
    # picked_card_indices is prepended (most recent first), so reverse it
    reversed_indices = Enum.reverse(shop_state.picked_card_indices)

    # Create a map of pick_number -> card for completed picks
    completed_picks =
      reversed_indices
      |> Enum.with_index()
      |> Enum.map(fn {card_idx, pick_num} ->
        {pick_num + 1, Enum.at(shop_state.available_cards, card_idx)}
      end)
      |> Map.new()

    # Total picks expected (2 per round)
    total_picks = shop_state.total_rounds * 2

    # Current pick number (1-indexed)
    current_pick_number = length(reversed_indices) + 1

    # Build all pick slots - only show as current if NOT in destroy phase
    pick_slots =
      for pick_num <- 1..total_picks do
        # Odd picks (1, 3, 5...) are first picker, even (2, 4, 6...) are second picker
        picker_name = if rem(pick_num, 2) == 1, do: first_picker_name, else: second_picker_name
        card = Map.get(completed_picks, pick_num)

        is_current =
          not in_destroy_phase and pick_num == current_pick_number and
            current_pick_number <= total_picks

        %{
          type: :pick,
          slot_number: pick_num,
          picker_name: picker_name,
          card: card,
          is_current: is_current,
          is_completed: card != nil
        }
      end

    all_slots = destroy_slots ++ pick_slots

    assigns =
      assigns
      |> assign(:all_slots, all_slots)

    ~H"""
    <div class="p-3 lg:p-6 border-b border-base-300/50">
      <!-- All slots - destroy slots first, then pick slots -->
      <div class="flex flex-wrap gap-2 lg:gap-3">
        <%= for slot <- @all_slots do %>
          <.timeline_slot
            slot_type={slot.type}
            slot_card={slot.card}
            picker_name={slot.picker_name}
            slot_number={slot.slot_number}
            is_current={slot.is_current}
            is_completed={slot.is_completed}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp timeline_slot(assigns) do
    card_display =
      case assigns[:slot_card] do
        %ShopCard{} = shop_card ->
          %{
            type: shop_card.type,
            name: ShopCard.card_name(shop_card),
            color: ShopCard.card_color(shop_card)
          }

        nil ->
          nil
      end

    is_destroy = assigns.slot_type == :destroy

    label =
      if is_destroy do
        "Destroy"
      else
        case assigns.slot_number do
          1 -> "1st"
          2 -> "2nd"
          3 -> "3rd"
          n -> "#{n}th"
        end
      end

    # For destroy slots, use rose colors; for pick slots, use emerald
    current_border_color = if is_destroy, do: "border-rose-400", else: "border-emerald-400"

    # Text shown below the card name - player name for picks, "Destroyed" for destroys
    subtext = if is_destroy, do: "Destroyed", else: assigns.picker_name

    assigns =
      assigns
      |> assign(:card_display, card_display)
      |> assign(:label, label)
      |> assign(:is_destroy, is_destroy)
      |> assign(:current_border_color, current_border_color)
      |> assign(:subtext, subtext)

    ~H"""
    <div class={[
      "flex-1 min-w-[110px] lg:min-w-[180px] flex-shrink-0 rounded-lg p-2 lg:p-3 border transition-all",
      cond do
        @card_display != nil -> "bg-base-100 border-base-300/50"
        @is_current -> ["bg-base-200/50 border-dashed animate-pulse", @current_border_color]
        true -> "bg-base-200/30 border-base-300/30"
      end
    ]}>
      <div class="text-[9px] lg:text-[10px] uppercase tracking-wider text-base-content/40 mb-0.5 lg:mb-1">
        {@label}
      </div>
      <%= if @card_display do %>
        <div class="flex items-center gap-1.5 lg:gap-2">
          <div class={[
            "w-1.5 h-1.5 lg:w-2 lg:h-2 rounded-full flex-shrink-0",
            case @card_display.color do
              "emerald" -> "bg-emerald-500"
              "rose" -> "bg-rose-500"
              "violet" -> "bg-violet-500"
              "amber" -> "bg-amber-500"
            end
          ]} />
          <div class="min-w-0">
            <div class="text-xs lg:text-sm font-medium text-base-content truncate">
              {@card_display.name}
            </div>
            <div class={[
              "text-[9px] lg:text-[10px]",
              if(@is_destroy, do: "text-rose-400", else: "text-base-content/40")
            ]}>
              {@subtext}
            </div>
          </div>
        </div>
      <% else %>
        <div class="text-xs lg:text-sm text-base-content/30">{@picker_name}</div>
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
    shop_card = assigns.shop_card
    display_name = ShopCard.card_name(shop_card)
    accent_color = ShopCard.card_color(shop_card)
    card_type = shop_card.type
    is_destroyed = assigns[:is_destroyed] || false
    in_destroy_phase = assigns[:in_destroy_phase] || false
    can_destroy = assigns[:can_destroy] || false

    # Determine click event based on phase
    click_event =
      cond do
        # Card is unavailable (picked or destroyed)
        assigns[:is_picked] or is_destroyed ->
          nil

        # Destroy phase - ONLY can click if can_destroy (waiting player can't click)
        in_destroy_phase ->
          if can_destroy, do: "preview_shop_card", else: nil

        # Normal pick phase
        assigns[:can_pick] ->
          case shop_card do
            %ShopCard{type: :deck_builder} -> "preview_deck_builder"
            %ShopCard{type: :sabotage, subtype: :plus_bomb} -> "preview_plus_bomb"
            _ -> "preview_shop_card"
          end

        true ->
          nil
      end

    # Card is disabled if it can't be clicked
    is_disabled = click_event == nil

    type_label = ShopCard.card_type_label(shop_card)

    assigns =
      assigns
      |> assign(:card_type, card_type)
      |> assign(:type_label, type_label)
      |> assign(:display_name, display_name)
      |> assign(:accent_color, accent_color)
      |> assign(:click_event, click_event)
      |> assign(:is_disabled, is_disabled)
      |> assign(:is_destroyed, is_destroyed)
      |> assign(:in_destroy_phase, in_destroy_phase)
      |> assign(:can_destroy, can_destroy)

    ~H"""
    <button
      phx-click={@click_event}
      phx-value-index={@index}
      disabled={@is_disabled}
      class={
        [
          "w-[100px] lg:w-full aspect-[2/3] rounded-xl p-2 lg:p-4 flex flex-col transition-all relative overflow-hidden flex-shrink-0",
          "bg-base-100 border-2",
          cond do
            # Destroyed cards
            @is_destroyed ->
              "opacity-50 cursor-not-allowed border-base-300/30"

            # Picked cards
            @is_picked ->
              "opacity-50 cursor-not-allowed border-base-300/30"

            # Selected for preview
            @is_selected ->
              case @accent_color do
                "emerald" -> "border-emerald-500 shadow-lg shadow-emerald-500/20 scale-[1.02]"
                "rose" -> "border-rose-500 shadow-lg shadow-rose-500/20 scale-[1.02]"
                "violet" -> "border-violet-500 shadow-lg shadow-violet-500/20 scale-[1.02]"
                "amber" -> "border-amber-500 shadow-lg shadow-amber-500/20 scale-[1.02]"
              end

            # Destroy phase - can destroy this card (same styling as normal pick)
            @in_destroy_phase and @can_destroy ->
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

            # Destroy phase - waiting player (can't destroy, disabled)
            @in_destroy_phase ->
              "border-base-300/30 cursor-not-allowed"

            # Normal pick phase - can pick
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
        ]
      }
    >
      <!-- Type badge at top -->
      <div class={[
        "text-[8px] lg:text-[10px] font-bold uppercase tracking-wider mb-1 lg:mb-2",
        case @accent_color do
          "emerald" -> "text-emerald-500"
          "rose" -> "text-rose-500"
          "violet" -> "text-violet-500"
          "amber" -> "text-amber-500"
        end
      ]}>
        {@type_label}
      </div>
      
    <!-- Card name centered -->
      <div class="flex-1 flex items-center justify-center">
        <div class={[
          "font-semibold text-xs lg:text-sm text-center leading-tight",
          cond do
            @is_destroyed -> "text-base-content/50"
            @is_picked -> "text-base-content/50"
            true -> "text-base-content"
          end
        ]}>
          {@display_name}
        </div>
      </div>

      <%= if @is_destroyed do %>
        <div class="absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl">
          <span class="text-xs text-rose-400 font-medium">Destroyed</span>
        </div>
      <% end %>

      <%= if @is_picked do %>
        <div class="absolute inset-0 bg-base-100/60 flex items-end justify-center pb-4 rounded-xl">
          <span class="text-xs text-base-content/40 font-medium">{@picked_by}</span>
        </div>
      <% end %>
    </button>
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

  defp has_pending_selection?(shop_state, player_id) do
    (shop_state.pending_deck_builder != nil and
       shop_state.pending_deck_builder.player_id == player_id) or
      (shop_state.pending_plus_bomb != nil and
         shop_state.pending_plus_bomb.player_id == player_id)
  end

  defp card_detail_panel(assigns) do
    # Set defaults
    assigns =
      assigns
      |> assign_new(:in_destroy_phase, fn -> false end)
      |> assign_new(:is_active_player, fn -> false end)

    ~H"""
    <div class="flex-1 flex flex-col">
      <%= case @shop_card do %>
        <% %ShopCard{type: :level_up, subtype: hand_type} -> %>
          <.level_up_detail
            hand_type={hand_type}
            skill_tree={@skill_tree}
            is_active_player={@is_active_player}
            in_destroy_phase={@in_destroy_phase}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
          />
        <% %ShopCard{type: type} = shop_card when type in [:sabotage, :denial] -> %>
          <.action_detail
            action_card={shop_card}
            is_active_player={@is_active_player}
            in_destroy_phase={@in_destroy_phase}
            action_in_progress={@action_in_progress}
            card_index={@card_index}
            pending_plus_bomb={@pending_plus_bomb}
            plus_bomb_selection={@plus_bomb_selection}
          />
        <% %ShopCard{type: :deck_builder} = shop_card -> %>
          <.deck_builder_detail
            deck_builder_card={shop_card}
            is_active_player={@is_active_player}
            in_destroy_phase={@in_destroy_phase}
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
    # Set defaults
    assigns =
      assigns
      |> assign_new(:in_destroy_phase, fn -> false end)
      |> assign_new(:is_active_player, fn -> false end)

    # Get upgrade bonus (constant for each hand type)
    upgrade_bonus = Oskol.Poker.Score.upgrade_bonuses()[assigns.hand_type]

    # Only calculate actual levels if this player is the active player
    {current_level, next_level, current_stats, next_stats} =
      if assigns.is_active_player do
        level = Map.get(assigns.skill_tree, assigns.hand_type, 1)

        {
          level,
          level + 1,
          Oskol.Poker.Score.stats_at_level(assigns.hand_type, level),
          Oskol.Poker.Score.stats_at_level(assigns.hand_type, level + 1)
        }
      else
        {nil, nil, nil, nil}
      end

    assigns =
      assigns
      |> assign(:current_level, current_level)
      |> assign(:next_level, next_level)
      |> assign(:current_stats, current_stats)
      |> assign(:next_stats, next_stats)
      |> assign(:upgrade_bonus, upgrade_bonus)
      |> assign(:hand_name, Format.hand_name(assigns.hand_type))

    ~H"""
    <div class="flex-1 flex flex-col p-4 lg:p-8 overflow-hidden">
      <!-- Scrollable content area -->
      <div class="flex-1 overflow-y-auto">
        <!-- Header -->
        <div class="mb-4 lg:mb-8">
          <div class="text-[10px] lg:text-xs uppercase tracking-widest text-emerald-500/60 mb-1">
            Research
          </div>
          <h2 class="text-2xl lg:text-4xl font-light text-base-content">{@hand_name}</h2>
        </div>
        
    <!-- Level indicator -->
        <div class="mb-6 lg:mb-12">
          <div class="flex items-center gap-3 lg:gap-4">
            <div class="flex items-center gap-1.5 lg:gap-2">
              <%= if @is_active_player do %>
                <span class="text-2xl lg:text-3xl font-light text-base-content/40">
                  {@current_level}
                </span>
              <% else %>
                <span class="text-2xl lg:text-3xl font-light text-base-content/40">?</span>
              <% end %>
              <svg
                class="w-4 h-4 lg:w-5 lg:h-5 text-emerald-500"
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
              <%= if @is_active_player do %>
                <span class="text-2xl lg:text-3xl font-medium text-emerald-500">{@next_level}</span>
              <% else %>
                <span class="text-2xl lg:text-3xl font-medium text-emerald-500">?</span>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Stats -->
        <div class="space-y-3 lg:space-y-6">
          <%= if @is_active_player do %>
            <!-- Active player: show current → new values with delta -->
            <div class="flex items-baseline justify-between border-b border-base-300/30 pb-2 lg:pb-4">
              <span class="text-base-content/50 text-xs lg:text-sm uppercase tracking-wider">
                Base Chips
              </span>
              <div class="flex items-center gap-1.5 lg:gap-3">
                <span class="text-base-content/30 text-base lg:text-lg">
                  {@current_stats.base_chips}
                </span>
                <svg
                  class="w-3 h-3 lg:w-4 lg:h-4 text-base-content/20"
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
                <span class="text-emerald-500 text-lg lg:text-2xl font-medium">
                  {@next_stats.base_chips}
                </span>
                <span class="text-emerald-400 text-xs lg:text-sm font-medium">
                  (+{@upgrade_bonus.chips})
                </span>
              </div>
            </div>
            <div class="flex items-baseline justify-between border-b border-base-300/30 pb-2 lg:pb-4">
              <span class="text-base-content/50 text-xs lg:text-sm uppercase tracking-wider">
                Multiplier
              </span>
              <div class="flex items-center gap-1.5 lg:gap-3">
                <span class="text-base-content/30 text-base lg:text-lg">
                  {@current_stats.multiplier}x
                </span>
                <svg
                  class="w-3 h-3 lg:w-4 lg:h-4 text-base-content/20"
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
                <span class="text-emerald-500 text-lg lg:text-2xl font-medium">
                  {@next_stats.multiplier}x
                </span>
                <span class="text-emerald-400 text-xs lg:text-sm font-medium">
                  (+{@upgrade_bonus.multiplier})
                </span>
              </div>
            </div>
          <% else %>
            <!-- Waiting player: show only delta gained -->
            <div class="flex items-baseline justify-between border-b border-base-300/30 pb-2 lg:pb-4">
              <span class="text-base-content/50 text-xs lg:text-sm uppercase tracking-wider">
                Chips Gained
              </span>
              <span class="text-emerald-500 text-lg lg:text-2xl font-medium">
                +{@upgrade_bonus.chips}
              </span>
            </div>
            <div class="flex items-baseline justify-between border-b border-base-300/30 pb-2 lg:pb-4">
              <span class="text-base-content/50 text-xs lg:text-sm uppercase tracking-wider">
                Mult Gained
              </span>
              <span class="text-emerald-500 text-lg lg:text-2xl font-medium">
                +{@upgrade_bonus.multiplier}
              </span>
            </div>
            <div class="mt-3 lg:mt-4 p-3 lg:p-4 rounded-lg bg-base-200/50">
              <p class="text-base-content/50 text-xs lg:text-sm italic">
                Opponent's current level is hidden. Watch for their hand types during gameplay!
              </p>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Action Button: only shown for active player - fixed at bottom -->
      <%= if @is_active_player do %>
        <div class="pt-4 lg:pt-8 flex-shrink-0">
          <%= if @in_destroy_phase do %>
            <button
              phx-click="destroy_shop_card"
              phx-value-index={@card_index}
              disabled={@action_in_progress}
              class={[
                "w-full py-3 lg:py-4 rounded-full font-medium text-base lg:text-lg transition-all",
                if(@action_in_progress,
                  do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                  else: "bg-rose-500 text-white hover:bg-rose-600 shadow-lg hover:shadow-xl"
                )
              ]}
            >
              Destroy This Card
            </button>
          <% else %>
            <button
              phx-click="confirm_shop_pick"
              phx-value-index={@card_index}
              disabled={@action_in_progress}
              class={[
                "w-full py-3 lg:py-4 rounded-full font-medium text-base lg:text-lg transition-all",
                if(@action_in_progress,
                  do: "bg-base-300 text-base-content/40 cursor-not-allowed",
                  else: "bg-emerald-500 text-white hover:bg-emerald-600 shadow-lg hover:shadow-xl"
                )
              ]}
            >
              Confirm Selection
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp action_detail(assigns) do
    # Set defaults
    assigns =
      assigns
      |> assign_new(:in_destroy_phase, fn -> false end)
      |> assign_new(:is_active_player, fn -> false end)

    shop_card = assigns.action_card
    card_name = ShopCard.card_name(shop_card)
    card_description = ShopCard.card_description(shop_card)
    is_scrambler = shop_card.subtype == :scrambler
    requires_selection = ShopCard.requires_selection?(shop_card)

    # For denial cards, show the target hand
    hand_name =
      if shop_card.type == :denial do
        Format.hand_name(shop_card.subtype)
      else
        nil
      end

    accent_color = ShopCard.card_color(shop_card)
    type_label = ShopCard.card_type_label(shop_card)

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
      |> assign(:requires_selection, requires_selection)
      |> assign(:has_plus_bomb_preview, has_plus_bomb_preview)

    ~H"""
    <div class="flex-1 flex flex-col p-4 lg:p-8 overflow-hidden">
      <!-- Scrollable content area -->
      <div class="flex-1 overflow-y-auto">
        <!-- Header -->
        <div class="mb-4 lg:mb-8">
          <div class={[
            "text-[10px] lg:text-xs uppercase tracking-widest mb-1",
            if(@accent_color == "amber", do: "text-amber-500/60", else: "text-rose-500/60")
          ]}>
            {@type_label}
          </div>
          <h2 class="text-2xl lg:text-4xl font-light text-base-content">{@card_name}</h2>
        </div>

        <%= if @hand_name do %>
          <!-- Target for denial cards -->
          <div class="mb-4 lg:mb-8">
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
          <div class="mb-4 lg:mb-8">
            <div class="inline-flex items-center gap-2 px-3 lg:px-4 py-1.5 lg:py-2 rounded-full bg-amber-500/10">
              <svg
                class="w-3 h-3 lg:w-4 lg:h-4 text-amber-500"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              <span class="text-amber-500 text-sm lg:text-base font-medium">1-in-5 face-down</span>
            </div>
          </div>
        <% end %>
        
    <!-- Description -->
        <div class="mb-4 lg:mb-8">
          <p class="text-base-content/60 text-sm lg:text-lg leading-relaxed">{@card_description}</p>
        </div>
      </div>

      <%= if @has_plus_bomb_preview do %>
        <!-- Plus Bomb card selection -->
        <div class="mb-4">
          <span class="text-sm text-base-content/50">
            Select a card - that rank AND suit won't score for opponent
          </span>
        </div>
        
    <!-- 8-Card Selection Grid for Plus Bomb -->
        <div class="flex-1 mb-4 lg:mb-6">
          <div class="flex flex-wrap gap-2 lg:gap-3">
            <%= for card <- @pending_plus_bomb.available_cards do %>
              <% is_selected = @plus_bomb_selection == card.id %>
              <.plus_bomb_card_minimal
                card={card}
                selected={is_selected}
              />
            <% end %>
          </div>
        </div>
        
    <!-- Action Button for Plus Bomb selection phase -->
        <%= if @is_active_player and @plus_bomb_selection do %>
          <div class="pt-4">
            <%= if @in_destroy_phase do %>
              <button
                phx-click="destroy_shop_card"
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
                Destroy This Card
              </button>
            <% else %>
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
            <% end %>
          </div>
        <% end %>
      <% else %>
        <!-- Action Button: only shown for active player - fixed at bottom -->
        <%= if @is_active_player do %>
          <div class="pt-4 lg:pt-8 flex-shrink-0">
            <%= if @in_destroy_phase do %>
              <button
                phx-click="destroy_shop_card"
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
                Destroy This Card
              </button>
            <% else %>
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
        "w-[70px] lg:w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden",
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
    # Set defaults
    assigns =
      assigns
      |> assign_new(:in_destroy_phase, fn -> false end)
      |> assign_new(:is_active_player, fn -> false end)

    shop_card = assigns.deck_builder_card
    card_name = ShopCard.card_name(shop_card)
    card_description = ShopCard.card_description(shop_card)

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
    <div class="flex-1 flex flex-col p-4 lg:p-8 overflow-hidden">
      <!-- Header -->
      <div class="mb-4 lg:mb-6 flex-shrink-0">
        <div class="text-[10px] lg:text-xs uppercase tracking-widest text-violet-500/60 mb-1">
          Logistics
        </div>
        <h2 class="text-2xl lg:text-4xl font-light text-base-content">{@card_name}</h2>
      </div>

      <%= if @has_preview do %>
        <!-- Selection instruction -->
        <div class="mb-4 flex-shrink-0">
          <% instruction = ShopCard.selection_instruction(@pending_deck_builder.deck_builder_card) %>
          <span class="text-sm text-base-content/50">{instruction}</span>
        </div>
        
    <!-- 8-Card Selection Grid -->
        <div class="mb-4 lg:mb-6 flex-shrink-0">
          <div class="flex flex-wrap gap-2 lg:gap-3">
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
        
    <!-- Spacer to push button to bottom -->
        <div class="flex-1"></div>
        
    <!-- Action Buttons: only shown for active player - fixed at bottom -->
        <%= if @is_active_player do %>
          <div class="flex-shrink-0">
            <%= if @in_destroy_phase do %>
              <button
                phx-click="destroy_shop_card"
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
                Destroy This Card
              </button>
            <% else %>
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
          </div>
        <% end %>
      <% else %>
        <!-- Description (shown before card selection) -->
        <div class="mb-4 lg:mb-8 flex-shrink-0">
          <p class="text-base-content/60 text-sm lg:text-lg leading-relaxed">{@card_description}</p>
        </div>
        
    <!-- Spacer to push button to bottom -->
        <div class="flex-1"></div>
        
    <!-- Initial confirm button: only shown for active player - fixed at bottom -->
        <%= if @is_active_player do %>
          <div class="flex-shrink-0">
            <%= if @in_destroy_phase do %>
              <button
                phx-click="destroy_shop_card"
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
                Destroy This Card
              </button>
            <% else %>
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
            <% end %>
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
        "w-[70px] lg:w-[100px] transition-all cursor-pointer rounded-lg overflow-hidden",
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
