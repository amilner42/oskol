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
          />
        <%!-- Second picker's turn --%>
        <% @shop_state.first_pick_made and not @shop_state.second_pick_made and
            @shop_state.second_picker_id == @player_id -> %>
          <.pick_interface
            message="Your turn to pick!"
            can_pick={true}
            action_in_progress={@action_in_progress}
          />
        <%!-- Waiting for first picker --%>
        <% not @shop_state.first_pick_made -> %>
          <.waiting_view
            message={"Waiting for #{@player_names[@shop_state.first_picker_id]} to pick first..."}
          />
        <%!-- Waiting for second picker --%>
        <% @shop_state.first_pick_made and not @shop_state.second_pick_made -> %>
          <.waiting_view
            message={"Waiting for #{@player_names[@shop_state.second_picker_id]} to pick..."}
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

  defp pick_interface(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-lg text-success font-bold mb-6">{@message}</div>

      <!-- 24 Placeholder Cards in 6x4 Grid -->
      <div class="grid grid-cols-6 gap-3 mb-6">
        <%= for i <- 1..24 do %>
          <div class="aspect-[2/3] bg-base-200 rounded-lg border-2 border-base-300 flex items-center justify-center hover:border-primary transition-colors">
            <span class="text-xs text-base-content/50">{i}</span>
          </div>
        <% end %>
      </div>

      <button
        phx-click="make_shop_pick"
        disabled={@action_in_progress or not @can_pick}
        class={[
          "px-8 py-4 rounded-lg font-bold text-lg transition-all shadow-lg",
          if(@action_in_progress or not @can_pick,
            do: "bg-base-content/30 cursor-not-allowed opacity-50 text-base-content",
            else: "bg-accent hover:bg-accent/90 text-accent-content hover:scale-[1.02]"
          )
        ]}
      >
        <%= if @action_in_progress do %>
          Picking...
        <% else %>
          Pick Card
        <% end %>
      </button>
    </div>
    """
  end

  defp waiting_view(assigns) do
    ~H"""
    <div>
      <div class="text-center text-base-content/60 text-lg mb-6">{@message}</div>

      <!-- 24 Placeholder Cards in 6x4 Grid (non-interactive) -->
      <div class="grid grid-cols-6 gap-3 opacity-50">
        <%= for i <- 1..24 do %>
          <div class="aspect-[2/3] bg-base-200 rounded-lg border-2 border-base-300 flex items-center justify-center">
            <span class="text-xs text-base-content/50">{i}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

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
