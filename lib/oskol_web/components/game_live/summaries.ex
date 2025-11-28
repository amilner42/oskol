defmodule OskolWeb.Components.GameLive.Summaries do
  @moduledoc """
  Round and match summary screen components.
  """
  use OskolWeb, :html

  def round_summary_screen(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-base-200">
      <!-- Center content with modern card layout -->
      <div class="flex-1 flex flex-col justify-center px-4">
        <div class="max-w-4xl mx-auto w-full">
          <div class="bg-base-100 rounded-lg shadow-xl p-8 border border-base-300">
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
    <div class="min-h-screen flex items-center justify-center bg-gradient-to-br from-base-300 via-base-200 to-base-100">
      <div class="w-full max-w-2xl px-6">
        <div class="text-center mb-8">
          <div class="text-6xl mb-4">
            <%= if @game_state.winner_id == @player_id do %>
              🏆
            <% else %>
              💀
            <% end %>
          </div>
          <h3 class="text-4xl font-bold text-base-content mb-2">
            <%= if @game_state.winner_id == @player_id do %>
              Victory!
            <% else %>
              Defeat
            <% end %>
          </h3>
          <p class="text-base-content/60">
            Match complete after {@game_state.round_number} rounds
          </p>
        </div>

        <div class="grid grid-cols-2 gap-6 mb-8">
          <.player_result_card
            player_name={@player_name}
            lives={@player_state.lives}
            initial_lives={@game_state.initial_lives}
            is_winner={@game_state.winner_id == @player_id}
            color="text-player"
          />

          <.player_result_card
            player_name={@opponent_name}
            lives={@opponent_state.lives}
            initial_lives={@game_state.initial_lives}
            is_winner={@game_state.winner_id == @opponent_id}
            color="text-opponent"
          />
        </div>

        <div class="flex flex-col gap-3">
          <button
            phx-click="rematch"
            class="w-full px-8 py-4 rounded-xl font-bold text-lg text-white transition-all shadow-xl bg-gradient-to-r from-blue-600 to-blue-500 hover:from-blue-700 hover:to-blue-600 hover:shadow-2xl hover:scale-[1.02] active:scale-[0.98]"
          >
            Rematch
          </button>
          <a
            href="/"
            class="w-full px-6 py-3 rounded-xl font-medium text-base-content/70 text-center transition-all bg-base-100 hover:bg-base-200 border border-base-300"
          >
            Back to Home
          </a>
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
        <div class="text-2xl font-bold text-base-content mb-6">
          Round {@game_state.round_number} Complete!
        </div>
        <div class="grid grid-cols-2 gap-8 mb-8">
          <div class="bg-base-200 rounded-lg p-6">
            <div class="font-bold text-player text-lg mb-3">{@player_name}</div>
            <div class="text-base-content/70 mb-2">
              Score: <span class="text-base-content font-semibold text-xl">{player_score}</span>
            </div>
            <%= cond do %>
              <% outcome == :player_won -> %>
                <div class="text-success mt-2 font-semibold">✓ Round Winner!</div>
              <% outcome == :opponent_won -> %>
                <div class="text-error mt-2">✗ Round Lost (-1 Life)</div>
              <% outcome == :tie -> %>
                <div class="text-base-content/70 mt-2">= Tie (No Life Lost)</div>
            <% end %>
            <div class="mt-4 text-sm text-base-content/60">
              Lives: {@player_state.lives}
            </div>
          </div>
          <div class="bg-base-200 rounded-lg p-6">
            <div class="font-bold text-opponent text-lg mb-3">{@opponent_name}</div>
            <div class="text-base-content/70 mb-2">
              Score: <span class="text-base-content font-semibold text-xl">{opponent_score}</span>
            </div>
            <%= cond do %>
              <% outcome == :opponent_won -> %>
                <div class="text-success mt-2 font-semibold">✓ Round Winner!</div>
              <% outcome == :player_won -> %>
                <div class="text-error mt-2">✗ Round Lost (-1 Life)</div>
              <% outcome == :tie -> %>
                <div class="text-base-content/70 mt-2">= Tie (No Life Lost)</div>
            <% end %>
            <div class="mt-4 text-sm text-base-content/60">
              Lives: {@opponent_state.lives}
            </div>
          </div>
        </div>

        <%= cond do %>
          <%!-- No shop - Show ready status --%>
          <% @game_state.shop_state == nil && @game_state.game_status != :game_over -> %>
            <div class="mt-8">
              <.ready_status_display
                player_name={@player_name}
                opponent_name={@opponent_name}
                player_ready={@player_state.ready_for_next_round}
                opponent_ready={@opponent_state.ready_for_next_round}
              />

              <div class="flex justify-center gap-4 mt-4">
                <button
                  phx-click="dismiss_round_summary"
                  class="skip-button-10s px-4 py-2 bg-base-100 hover:bg-base-200 rounded text-base-content transition-colors"
                >
                  <span class="skip-button-text">Skip Match Summary</span>
                </button>
                <button
                  phx-click="mark_ready"
                  disabled={@player_state.ready_for_next_round}
                  class={[
                    "px-8 py-3 rounded-lg font-semibold text-lg transition-all shadow-lg",
                    if(@player_state.ready_for_next_round,
                      do: "bg-base-content/30 cursor-not-allowed opacity-50 text-base-content",
                      else:
                        "bg-success hover:bg-success/90 hover:shadow-xl text-success-content hover:scale-[1.02]"
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

            <%!-- Game over or shop configured - show skip button --%>
          <% true -> %>
            <div class="mt-6 flex justify-center">
              <button
                phx-click="dismiss_round_summary"
                class="skip-button-10s px-4 py-2 bg-base-100 hover:bg-base-200 rounded text-base-content transition-colors"
              >
                <span class="skip-button-text">Skip Match Summary</span>
              </button>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  def player_result_card(assigns) do
    # Use initial_lives if provided, otherwise default to 3
    initial_lives = Map.get(assigns, :initial_lives, 3)
    assigns = assign(assigns, :initial_lives, initial_lives)

    ~H"""
    <div class={[
      "rounded-xl p-6 border-2 bg-base-100 shadow-lg",
      if(@is_winner,
        do: "border-success ring-2 ring-success/20",
        else: "border-base-300"
      )
    ]}>
      <h4 class={"text-xl font-bold mb-4 text-center #{@color}"}>
        {@player_name}
      </h4>
      <%= if @is_winner do %>
        <div class="text-2xl font-bold text-success text-center mb-4">
          Winner
        </div>
      <% else %>
        <div class="text-2xl font-bold text-error/60 text-center mb-4">
          Eliminated
        </div>
      <% end %>
      <div class="flex justify-center items-center gap-1.5 mb-3">
        <% lives = max(0, @lives) %>
        <% lost_lives = @initial_lives - lives %>
        <%= if lives > 0 do %>
          <%= for _i <- 1..lives do %>
            <.icon name="hero-heart-solid" class="w-8 h-8 text-error" />
          <% end %>
        <% end %>
        <%= if lost_lives > 0 do %>
          <%= for _i <- 1..lost_lives do %>
            <.icon name="hero-heart" class="w-8 h-8 text-base-content/20" />
          <% end %>
        <% end %>
      </div>
      <div class="text-center text-base-content/50 text-xs">
        {lives}/{@initial_lives} lives
      </div>
    </div>
    """
  end

  defp ready_status_display(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-4 border border-base-300">
      <div class="text-center text-sm text-base-content">
        <div class="mb-2">
          {@player_name}:
          <%= if @player_ready do %>
            <span class="text-success font-semibold">✓ Ready</span>
          <% else %>
            <span class="text-warning">Not Ready</span>
          <% end %>
        </div>
        <div>
          {@opponent_name}:
          <%= if @opponent_ready do %>
            <span class="text-success font-semibold">✓ Ready</span>
          <% else %>
            <span class="text-warning">Not Ready</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
