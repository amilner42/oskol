defmodule OskolWeb.Components.GameLive.Summaries do
  @moduledoc """
  Round and match summary screen components.
  """
  use OskolWeb, :html

  def round_summary_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen">
      <!-- Top 25% -->
      <div class="flex-1 bg-green-950"></div>

      <!-- Middle 50% - Round Summary -->
      <div class="flex-[2] flex flex-col justify-center p-4 border-t border-b border-yellow-800 bg-green-900">
        <.round_summary
          game_state={@game_state}
          player_name={@player_name}
          opponent_name={@opponent_name}
          player_state={@player_state}
          opponent_state={@opponent_state}
        />
      </div>

      <!-- Bottom 25% -->
      <div class="flex-1 bg-green-950"></div>
    </div>
    """
  end

  def match_summary_screen(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 bg-gray-900 min-h-screen">
      <div class="bg-gray-800 rounded-lg p-6 mb-6">
        <h3 class="text-3xl font-bold mb-8 text-center text-yellow-400">
          Match Complete!
        </h3>

        <div class="grid grid-cols-2 gap-6 mb-8">
          <.player_result_card
            player_name={@player_name}
            lives={@player_state.lives}
            is_winner={@game_state.winner_id == @player_id}
            color="text-blue-400"
          />

          <.player_result_card
            player_name={@opponent_name}
            lives={@opponent_state.lives}
            is_winner={@game_state.winner_id == @opponent_id}
            color="text-red-400"
          />
        </div>

        <div class="text-center text-gray-500">
          Game Over - Rounds Completed: {@game_state.round_number}
        </div>
      </div>
    </div>
    """
  end

  def round_summary(assigns) do
    ~H"""
    <div class="bg-gray-800 py-6 px-8 rounded">
      <div class="text-center">
        <div class="text-xl font-bold text-yellow-400 mb-4">
          Round {@game_state.round_number} Complete!
        </div>
        <div class="grid grid-cols-2 gap-4 text-sm mb-4">
          <div>
            <div class="font-bold text-blue-400 mb-1">{@player_name}</div>
            <div class="text-gray-400">
              Score: <span class="text-green-400 font-bold">{@player_state.current_round_score}</span>
            </div>
            <%= if @player_state.current_round_score >= @game_state.blind_target do %>
              <div class="text-green-400 mt-1">✓ Blind Cleared!</div>
            <% else %>
              <div class="text-red-400 mt-1">✗ Blind Failed (-1 Life)</div>
            <% end %>
          </div>
          <div>
            <div class="font-bold text-red-400 mb-1">{@opponent_name}</div>
            <div class="text-gray-400">
              Score: <span class="text-green-400 font-bold">{@opponent_state.current_round_score}</span>
            </div>
            <%= if @opponent_state.current_round_score >= @game_state.blind_target do %>
              <div class="text-green-400 mt-1">✓ Blind Cleared!</div>
            <% else %>
              <div class="text-red-400 mt-1">✗ Blind Failed (-1 Life)</div>
            <% end %>
          </div>
        </div>
        <div class="mt-4">
          <%= if @game_state.game_status == :game_over do %>
            <button
              phx-click="dismiss_round_summary"
              class="bg-purple-600 hover:bg-purple-700 px-6 py-2 rounded font-bold text-sm"
            >
              View Match Summary
            </button>
          <% else %>
            <button
              phx-click="dismiss_round_summary"
              class="bg-purple-600 hover:bg-purple-700 px-6 py-2 rounded font-bold text-sm"
            >
              Continue to Shop
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def player_result_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg p-8",
      if(@is_winner,
        do: "bg-green-800 border-4 border-green-400",
        else: "bg-gray-700"
      )
    ]}>
      <h4 class={"text-2xl font-bold mb-6 text-center #{@color}"}>
        {@player_name}
      </h4>
      <%= if @is_winner do %>
        <div class="text-4xl font-bold text-green-400 text-center mb-6">
          🏆 WINNER!
        </div>
      <% end %>
      <div class="flex justify-center items-center gap-2 mb-4">
        <% lives = max(0, @lives) %>
        <%= if lives > 0 do %>
          <%= for _i <- 1..lives do %>
            <.icon name="hero-heart" class="w-12 h-12 text-red-500" />
          <% end %>
        <% end %>
        <%= if lives < 3 do %>
          <%= for _i <- 1..(3 - lives) do %>
            <.icon name="hero-heart" class="w-12 h-12 text-gray-600" />
          <% end %>
        <% end %>
      </div>
      <div class="text-center text-gray-400 text-sm">
        {@lives} {if @lives == 1, do: "Life", else: "Lives"} Remaining
      </div>
    </div>
    """
  end
end
