defmodule OskolWeb.Components.GameLive.Summaries do
  @moduledoc """
  Round and match summary screen components.
  """
  use OskolWeb, :html

  def round_summary_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen" style="background-color: #FBFBFB;">
      <!-- Center content with modern card layout -->
      <div class="flex-1 flex flex-col justify-center px-4">
        <div class="max-w-4xl mx-auto w-full">
          <div class="bg-white rounded-lg shadow-md p-8 border border-gray-200">
            <.round_summary
              game_state={@game_state}
              player_name={@player_name}
              opponent_name={@opponent_name}
              player_state={@player_state}
              opponent_state={@opponent_state}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  def match_summary_screen(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center" style="background-color: #FBFBFB;">
      <div class="w-full max-w-4xl px-6">
        <div class="bg-white rounded-lg shadow-lg p-8 border border-gray-200">
          <h3 class="text-3xl font-bold mb-8 text-center text-gray-900">
            Match Complete!
          </h3>

          <div class="grid grid-cols-2 gap-6 mb-8">
            <.player_result_card
              player_name={@player_name}
              lives={@player_state.lives}
              is_winner={@game_state.winner_id == @player_id}
              color="text-blue-600"
            />

            <.player_result_card
              player_name={@opponent_name}
              lives={@opponent_state.lives}
              is_winner={@game_state.winner_id == @opponent_id}
              color="text-red-600"
            />
          </div>

          <div class="text-center text-gray-500 text-sm">
            Game Over - Rounds Completed: {@game_state.round_number}
          </div>
        </div>
      </div>
    </div>
    """
  end

  def round_summary(assigns) do
    ~H"""
    <% # Determine round outcome
    player_score = @player_state.current_round_score
    opponent_score = @opponent_state.current_round_score

    outcome =
      cond do
        player_score > opponent_score -> :player_won
        opponent_score > player_score -> :opponent_won
        true -> :tie
      end %>

    <div>
      <div class="text-center">
        <div class="text-2xl font-bold text-gray-900 mb-6">
          Round {@game_state.round_number} Complete!
        </div>
        <div class="grid grid-cols-2 gap-8 mb-8">
          <div class="bg-gray-50 rounded-lg p-6">
            <div class="font-bold text-blue-600 text-lg mb-3">{@player_name}</div>
            <div class="text-gray-600 mb-2">
              Score: <span class="text-gray-900 font-semibold text-xl">{player_score}</span>
            </div>
            <%= cond do %>
              <% outcome == :player_won -> %>
                <div class="text-green-600 mt-2 font-semibold">✓ Round Winner!</div>
              <% outcome == :opponent_won -> %>
                <div class="text-red-600 mt-2">✗ Round Lost (-1 Life)</div>
              <% outcome == :tie -> %>
                <div class="text-gray-600 mt-2">= Tie (No Life Lost)</div>
            <% end %>
            <div class="mt-4 text-sm text-gray-500">
              Lives: {@player_state.lives}
            </div>
          </div>
          <div class="bg-gray-50 rounded-lg p-6">
            <div class="font-bold text-red-600 text-lg mb-3">{@opponent_name}</div>
            <div class="text-gray-600 mb-2">
              Score: <span class="text-gray-900 font-semibold text-xl">{opponent_score}</span>
            </div>
            <%= cond do %>
              <% outcome == :opponent_won -> %>
                <div class="text-green-600 mt-2 font-semibold">✓ Round Winner!</div>
              <% outcome == :player_won -> %>
                <div class="text-red-600 mt-2">✗ Round Lost (-1 Life)</div>
              <% outcome == :tie -> %>
                <div class="text-gray-600 mt-2">= Tie (No Life Lost)</div>
            <% end %>
            <div class="mt-4 text-sm text-gray-500">
              Lives: {@opponent_state.lives}
            </div>
          </div>
        </div>

        <%= cond do %>
          <%!-- Game Over - Show match summary button --%>
          <% @game_state.game_status == :game_over -> %>
            <div class="mt-6">
              <button
                phx-click="dismiss_round_summary"
                class="bg-gray-900 hover:bg-gray-800 text-white px-8 py-3 rounded-lg font-semibold transition-all shadow-md hover:shadow-lg"
              >
                View Match Summary
              </button>
            </div>

          <%!-- Shop configured - Continue to shop --%>
          <% @game_state.shop_state != nil -> %>
            <div class="mt-6">
              <button
                phx-click="dismiss_round_summary"
                class="bg-gray-900 hover:bg-gray-800 text-white px-8 py-3 rounded-lg font-semibold transition-all shadow-md hover:shadow-lg"
              >
                Continue to Shop
              </button>
            </div>

          <%!-- No shop - Show ready status --%>
          <% true -> %>
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
                  disabled={@player_state.ready_for_next_round}
                  class={[
                    "px-8 py-3 rounded-lg font-semibold text-lg transition-all shadow-md",
                    if(@player_state.ready_for_next_round,
                      do: "bg-gray-600 cursor-not-allowed opacity-50 text-white",
                      else: "bg-green-600 hover:bg-green-700 hover:shadow-lg text-white"
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
      </div>
    </div>
    """
  end

  def player_result_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg p-8 border-2",
      if(@is_winner,
        do: "bg-green-50 border-green-400",
        else: "bg-gray-50 border-gray-200"
      )
    ]}>
      <h4 class={"text-2xl font-bold mb-6 text-center #{@color}"}>
        {@player_name}
      </h4>
      <%= if @is_winner do %>
        <div class="text-4xl font-bold text-green-600 text-center mb-6">
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
            <.icon name="hero-heart" class="w-12 h-12 text-gray-300" />
          <% end %>
        <% end %>
      </div>
      <div class="text-center text-gray-600 text-sm font-medium">
        {@lives} {if @lives == 1, do: "Life", else: "Lives"} Remaining
      </div>
    </div>
    """
  end

  defp ready_status_display(assigns) do
    ~H"""
    <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
      <div class="text-center text-sm text-gray-700">
        <div class="mb-2">
          {@player_name}: <%= if @player_ready do %>
            <span class="text-green-600 font-semibold">✓ Ready</span>
          <% else %>
            <span class="text-yellow-600">Not Ready</span>
          <% end %>
        </div>
        <div>
          {@opponent_name}: <%= if @opponent_ready do %>
            <span class="text-green-600 font-semibold">✓ Ready</span>
          <% else %>
            <span class="text-yellow-600">Not Ready</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
