defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components for the turn-based upgrade system.
  """
  use OskolWeb, :html

  def shop_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-gray-800 rounded-lg p-6 mb-6">
        <h3 class="text-2xl font-bold mb-6 text-center text-cyan-400">Shop</h3>

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
                    "px-6 py-3 rounded font-bold text-lg transition-colors",
                    if(@action_in_progress or @player_state.ready_for_next_round,
                      do: "bg-gray-600 cursor-not-allowed opacity-50",
                      else: "bg-green-600 hover:bg-green-700"
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
          <div class="bg-gray-700 rounded-lg p-8 mb-6 text-center">
            <p class="text-gray-400 text-xl">Loading shop...</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp shop_status(assigns) do
    ~H"""
    <div class="bg-gray-700 rounded-lg p-4 mb-6">
      <div class="flex items-center justify-between text-sm">
        <div class="text-gray-300">
          Shop Round: <span class="text-cyan-400 font-bold">
            {@shop_state.current_round}/{@shop_state.total_rounds}
          </span>
        </div>
        <div class="text-gray-300">
          First Pick: <span class="text-green-400 font-bold">
            {@player_names[@shop_state.first_picker_id]}
          </span>
          <%= if @shop_state.first_pick_made do %>
            <span class="text-green-400 ml-1">✓</span>
          <% end %>
        </div>
        <div class="text-gray-300">
          Second Pick: <span class="text-blue-400 font-bold">
            {@player_names[@shop_state.second_picker_id]}
          </span>
          <%= if @shop_state.second_pick_made do %>
            <span class="text-green-400 ml-1">✓</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp picking_view(assigns) do
    ~H"""
    <div class="bg-gray-700 rounded-lg p-8 mb-6">
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
          <div class="text-center text-green-400 text-lg">
            Both players have picked! Moving to next round...
          </div>
      <% end %>
    </div>
    """
  end

  defp pick_interface(assigns) do
    ~H"""
    <div class="text-center">
      <div class="text-lg text-green-400 font-bold mb-6">{@message}</div>

      <!-- 24 Placeholder Cards in 6x4 Grid -->
      <div class="grid grid-cols-6 gap-3 mb-6">
        <%= for i <- 1..24 do %>
          <div class="aspect-[2/3] bg-gray-800 rounded-lg border-2 border-gray-600 flex items-center justify-center hover:border-purple-400 transition-colors">
            <span class="text-xs text-gray-500">{i}</span>
          </div>
        <% end %>
      </div>

      <button
        phx-click="make_shop_pick"
        disabled={@action_in_progress or not @can_pick}
        class={[
          "px-8 py-4 rounded-lg font-bold text-lg transition-colors",
          if(@action_in_progress or not @can_pick,
            do: "bg-gray-600 cursor-not-allowed opacity-50",
            else: "bg-purple-600 hover:bg-purple-700"
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
      <div class="text-center text-gray-400 text-lg mb-6">{@message}</div>

      <!-- 24 Placeholder Cards in 6x4 Grid (non-interactive) -->
      <div class="grid grid-cols-6 gap-3 opacity-50">
        <%= for i <- 1..24 do %>
          <div class="aspect-[2/3] bg-gray-800 rounded-lg border-2 border-gray-600 flex items-center justify-center">
            <span class="text-xs text-gray-500">{i}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp ready_status_display(assigns) do
    ~H"""
    <div class="bg-gray-700 rounded-lg p-4 mb-4">
      <div class="text-center text-sm text-gray-300">
        <div class="mb-2">
          {@player_name}: <%= if @player_ready do %>
            <span class="text-green-400">✓ Ready</span>
          <% else %>
            <span class="text-yellow-400">Not Ready</span>
          <% end %>
        </div>
        <div>
          {@opponent_name}: <%= if @opponent_ready do %>
            <span class="text-green-400">✓ Ready</span>
          <% else %>
            <span class="text-yellow-400">Not Ready</span>
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
