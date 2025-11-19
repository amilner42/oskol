defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components for the turn-based upgrade system.
  """
  use OskolWeb, :html

  def shop_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-base-100 min-h-screen">
      <div class="bg-base-200 rounded-lg p-6 mb-6 border border-base-300">
        <h3 class="text-2xl font-bold mb-6 text-center text-primary">Shop</h3>

        <%= if @game_state.shop_state do %>
          <.shop_status shop_state={@game_state.shop_state} player_names={@game_state.player_names} />

          <.picking_view
            shop_state={@game_state.shop_state}
            player_id={@player_id}
            player_names={@game_state.player_names}
            action_in_progress={@action_in_progress}
            game_state={@game_state}
          />

          <%= if shop_complete?(@game_state.shop_state) do %>
            <div class="mt-8">
              <.ready_status_display
                player_name={@player_name}
                opponent_name={@opponent_name}
                player_ready={@player_state.ready_for_next_round}
                opponent_ready={@opponent_state.ready_for_next_round}
              />

              <div class="flex justify-center mt-4">
                <button
                  phx-click="mark_ready"
                  disabled={@action_in_progress or @player_state.ready_for_next_round}
                  class={[
                    "px-6 py-3 rounded font-bold text-lg transition-all shadow-lg",
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
          <% end %>
        <% else %>
          <div class="bg-base-300 rounded-lg p-8 mb-6 text-center">
            <p class="text-base-content/60 text-xl">Loading shop...</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp shop_status(assigns) do
    ~H"""
    <div class="bg-base-300 rounded-lg p-4 mb-6">
      <div class="flex items-center justify-between text-sm">
        <div class="text-base-content/80">
          Shop Round: <span class="text-primary font-bold">
            {@shop_state.current_round}/{@shop_state.total_rounds}
          </span>
        </div>
        <div class="text-base-content/80">
          First Pick: <span class="text-success font-bold">
            {@player_names[@shop_state.first_picker_id]}
          </span>
          <%= if @shop_state.first_pick_made do %>
            <span class="text-success ml-1">✓</span>
          <% end %>
        </div>
        <div class="text-base-content/80">
          Second Pick: <span class="text-info font-bold">
            {@player_names[@shop_state.second_picker_id]}
          </span>
          <%= if @shop_state.second_pick_made do %>
            <span class="text-success ml-1">✓</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp picking_view(assigns) do
    ~H"""
    <div class="bg-base-300 rounded-lg p-8 mb-6">
      <%= cond do %>
        <%!-- First picker's turn --%>
        <% not @shop_state.first_pick_made and @shop_state.first_picker_id == @player_id -> %>
          <.pick_interface
            message="Your turn to pick first!"
            can_pick={true}
            action_in_progress={@action_in_progress}
            shop_state={@shop_state}
            skill_tree={skill_tree_for_player(@player_id, assigns)}
          />
        <%!-- Second picker's turn --%>
        <% @shop_state.first_pick_made and not @shop_state.second_pick_made and
            @shop_state.second_picker_id == @player_id -> %>
          <.pick_interface
            message="Your turn to pick!"
            can_pick={true}
            action_in_progress={@action_in_progress}
            shop_state={@shop_state}
            skill_tree={skill_tree_for_player(@player_id, assigns)}
          />
        <%!-- Waiting for first picker --%>
        <% not @shop_state.first_pick_made -> %>
          <.waiting_view
            message={"Waiting for #{@player_names[@shop_state.first_picker_id]} to pick first..."}
            shop_state={@shop_state}
            skill_tree={skill_tree_for_player(@player_id, assigns)}
          />
        <%!-- Waiting for second picker --%>
        <% @shop_state.first_pick_made and not @shop_state.second_pick_made -> %>
          <.waiting_view
            message={"Waiting for #{@player_names[@shop_state.second_picker_id]} to pick..."}
            shop_state={@shop_state}
            skill_tree={skill_tree_for_player(@player_id, assigns)}
          />
        <%!-- Both have picked --%>
        <% true -> %>
          <div class="text-center text-success text-lg">
            Both players have picked! Moving to next round...
          </div>
      <% end %>
    </div>
    """
  end

  defp skill_tree_for_player(player_id, assigns) do
    # Extract skill tree from game state for the given player
    player_state = assigns.game_state.players[player_id]
    player_state && player_state.skill_tree
  end

  defp pick_interface(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-lg text-success font-bold mb-6">{@message}</div>

      <!-- 18 Upgrade Cards in 6x3 Grid -->
      <div class="grid grid-cols-6 gap-3">
        <%= for {hand_type, index} <- Enum.with_index(@shop_state.available_upgrades) do %>
          <.upgrade_card
            hand_type={hand_type}
            index={index}
            skill_tree={@skill_tree}
            is_picked={index in @shop_state.picked_upgrades}
            can_pick={@can_pick and not @action_in_progress}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp waiting_view(assigns) do
    ~H"""
    <div>
      <div class="text-center text-base-content/60 text-lg mb-6">{@message}</div>

      <!-- 18 Upgrade Cards in 6x3 Grid (non-interactive) -->
      <div class="grid grid-cols-6 gap-3 opacity-50">
        <%= for {hand_type, index} <- Enum.with_index(@shop_state.available_upgrades) do %>
          <.upgrade_card
            hand_type={hand_type}
            index={index}
            skill_tree={@skill_tree}
            is_picked={index in @shop_state.picked_upgrades}
            can_pick={false}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp upgrade_card(assigns) do
    # Calculate current and next level stats
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
    <button
      phx-click={if @can_pick and not @is_picked, do: "make_shop_pick", else: nil}
      phx-value-index={@index}
      disabled={@is_picked or not @can_pick}
      class={[
        "aspect-[2/3] rounded-lg border-2 p-2 flex flex-col justify-between transition-all text-left",
        if(@is_picked,
          do: "bg-base-100/30 border-base-300 opacity-40 cursor-not-allowed",
          else:
            if(@can_pick,
              do: "bg-base-100 border-accent hover:border-accent hover:scale-[1.05] hover:shadow-lg cursor-pointer",
              else: "bg-base-100 border-base-300 cursor-default"
            )
        )
      ]}
    >
      <!-- Hand Type Name -->
      <div class="font-bold text-xs leading-tight text-primary">
        {@hand_name}
      </div>

      <!-- Level Info -->
      <div class="text-[10px] text-center my-1">
        <div class="text-base-content/60">
          Lvl {@current_level} → {@next_level}
        </div>
      </div>

      <!-- Stats -->
      <div class="text-[9px] space-y-1">
        <div class="text-base-content/80">
          <span class="line-through opacity-60">{@current_stats.base_chips}c</span>
          →
          <span class="text-success font-bold">{@next_stats.base_chips}c</span>
        </div>
        <div class="text-base-content/80">
          <span class="line-through opacity-60">{@current_stats.multiplier}x</span>
          →
          <span class="text-success font-bold">{@next_stats.multiplier}x</span>
        </div>
      </div>

      <%= if @is_picked do %>
        <div class="text-center mt-1">
          <span class="text-[10px] text-error font-bold">PICKED</span>
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
          {@player_name}: <%= if @player_ready do %>
            <span class="text-success">✓ Ready</span>
          <% else %>
            <span class="text-warning">Not Ready</span>
          <% end %>
        </div>
        <div>
          {@opponent_name}: <%= if @opponent_ready do %>
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
end
