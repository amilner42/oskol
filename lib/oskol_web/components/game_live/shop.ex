defmodule OskolWeb.Components.GameLive.Shop do
  @moduledoc """
  Shop screen components.
  """
  use OskolWeb, :html

  def shop_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-gray-800 rounded-lg p-6 mb-6">
        <h3 class="text-2xl font-bold mb-6 text-center text-cyan-400">Shop</h3>

        <div class="bg-gray-700 rounded-lg p-8 mb-6 text-center">
          <p class="text-gray-400 text-xl mb-4">Shop Coming Soon!</p>
          <p class="text-gray-500 text-sm">Click Ready to start the next round</p>
        </div>

        <div class="flex flex-col items-center gap-4">
          <.ready_status_display
            player_name={@player_name}
            opponent_name={@opponent_name}
            player_ready={@player_state.ready_for_next_round}
            opponent_ready={@opponent_state.ready_for_next_round}
          />

          <button
            phx-click="mark_ready"
            disabled={@action_in_progress or @player_state.ready_for_next_round}
            class={[
              "px-8 py-4 rounded font-bold text-xl",
              if(@action_in_progress or @player_state.ready_for_next_round,
                do: "bg-gray-600 cursor-not-allowed",
                else: "bg-green-600 hover:bg-green-700"
              )
            ]}
          >
            <%= cond do %>
              <% @player_state.ready_for_next_round -> %>
                Ready! Waiting for opponent...
              <% @action_in_progress -> %>
                Marking Ready...
              <% true -> %>
                I'm Ready
            <% end %>
          </button>
        </div>
      </div>
    </div>
    """
  end

  def ready_status_display(assigns) do
    ~H"""
    <div class="flex gap-8 text-lg">
      <div class="flex items-center gap-2">
        <span class="text-blue-400">{@player_name}:</span>
        <%= if @player_ready do %>
          <span class="text-green-400 font-bold">✓ Ready</span>
        <% else %>
          <span class="text-gray-400">Not Ready</span>
        <% end %>
      </div>
      <div class="flex items-center gap-2">
        <span class="text-red-400">{@opponent_name}:</span>
        <%= if @opponent_ready do %>
          <span class="text-green-400 font-bold">✓ Ready</span>
        <% else %>
          <span class="text-gray-400">Not Ready</span>
        <% end %>
      </div>
    </div>
    """
  end
end
