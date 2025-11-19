defmodule OskolWeb.Components.GameLive.History do
  @moduledoc """
  History modal component for viewing game event log.
  """
  use OskolWeb, :html

  alias Oskol.Game.EventLog

  def history_modal(assigns) do
    ~H"""
    <%= if @viewing_history do %>
      <!-- Modal backdrop -->
      <div
        class="fixed inset-0 backdrop-blur-sm bg-base-100/50 z-50 flex items-center justify-center p-4"
        phx-click="toggle_history"
      >
        <!-- Modal content (click inside won't close) -->
        <div
          class="bg-base-100 rounded-lg shadow-xl max-w-4xl w-full max-h-[80vh] flex flex-col border border-base-300"
          phx-click={JS.push("noop")}
        >
          <!-- Header -->
          <div class="flex items-center justify-between p-6 border-b border-base-300">
            <h2 class="text-2xl font-bold text-base-content">Game History</h2>
            <button
              phx-click="toggle_history"
              class="text-base-content/60 hover:text-base-content text-2xl font-bold"
            >
              ×
            </button>
          </div>

          <!-- Event list -->
          <div class="flex-1 overflow-y-auto p-6">
            <div class="space-y-3">
              <%= for event <- EventLog.get_all(@event_log) do %>
                <.event_item
                  event={event}
                  player_names={@player_names}
                  current_player_id={@player_id}
                />
              <% end %>
            </div>
          </div>

          <!-- Footer -->
          <div class="p-4 border-t border-base-300 text-center text-sm text-base-content/60">
            Total Events: {EventLog.count(@event_log)}
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp event_item(assigns) do
    ~H"""
    <div class="bg-base-200 rounded p-4 border-l-4" style={"border-color: #{event_color(@event.type)}"}>
      <div class="flex items-start justify-between gap-4">
        <div class="flex-1">
          <div class="flex items-center gap-2 mb-1">
            <span class="font-bold text-sm" style={"color: #{event_color(@event.type)}"}>
              {event_type_display(@event.type)}
            </span>
            <span class="text-xs text-base-content/50">
              #{@event.sequence}
            </span>
          </div>

          <.event_details event={@event} player_names={@player_names} current_player_id={@current_player_id} />
        </div>

        <div class="text-xs text-base-content/50 whitespace-nowrap">
          {format_timestamp(@event.timestamp)}
        </div>
      </div>
    </div>
    """
  end

  defp event_details(assigns) do
    ~H"""
    <div class="text-sm text-base-content/80">
      <%= case @event.type do %>
        <% :player_joined -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          joined the game

        <% :player_disconnected -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          disconnected

        <% :player_reconnected -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          reconnected

        <% :game_started -> %>
          Game started with {length(@event.data.player_ids)} players ({@event.data.initial_lives} lives each)

        <% :hand_locked_in -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          locked in {length(@event.data.cards)} cards

        <% :cards_discarded -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          discarded {length(@event.data.cards_discarded)} cards
          ({@event.data.discards_remaining} discards remaining)

        <% :cards_drawn -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          drew {length(@event.data.cards)} cards
          <span class="text-base-content/50">({format_draw_reason(@event.data.reason)})</span>

        <% :hands_revealed -> %>
          Both players revealed their hands
          <div class="mt-2 space-y-1">
            <%= for {player_id, result} <- @event.data.results do %>
              <div class="text-xs">
                <span class="font-semibold">{player_name(player_id, @player_names, @current_player_id)}:</span>
                <span class="text-accent">{format_hand_type(result.hand_type)}</span>
                for <span class="text-success font-bold">{result.score}</span> points
              </div>
            <% end %>
          </div>

        <% :round_completed -> %>
          <% winner_text = if @event.data.winner_id do
            player_name(@event.data.winner_id, @player_names, @current_player_id)
          else
            "Tie"
          end %>
          Round {@event.data.round_number} completed (Winner: {winner_text})
          <div class="mt-2 space-y-1">
            <%= for {player_id, result} <- @event.data.player_results do %>
              <div class="text-xs">
                <span class="font-semibold">{player_name(player_id, @player_names, @current_player_id)}:</span>
                {result.score} points
                <%= cond do %>
                  <% result.is_round_winner == true -> %>
                    <span class="text-success">✓ Won</span>
                  <% result.is_round_winner == false -> %>
                    <span class="text-error">✗ Lost (-1 life)</span>
                  <% true -> %>
                    <span class="text-warning">= Tied</span>
                <% end %>
                <span class="text-base-content/50">({result.lives} lives)</span>
              </div>
            <% end %>
          </div>

        <% :player_eliminated -> %>
          <span class="font-semibold text-error">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          was eliminated (Final score: {@event.data.final_score})

        <% :player_ready -> %>
          <span class="font-semibold">{player_name(@event.player_id, @player_names, @current_player_id)}</span>
          is ready for the next round

        <% :round_started -> %>
          Round {@event.data.round_number} started
          <div class="text-xs text-base-content/50">
            {Map.get(@event.data, :hands_remaining, "?")} hands, {Map.get(@event.data, :discards_remaining, "?")} discards
          </div>

        <% :game_ended -> %>
          <span class="font-bold text-warning">Game Over!</span>
          Winner: <span class="font-semibold">{player_name(@event.data.winner_id, @player_names, @current_player_id)}</span>
          <div class="text-xs text-base-content/50 mt-1">
            Final round: {@event.data.final_round}
          </div>

        <% _ -> %>
          {inspect(@event.type)} - {inspect(@event.data)}
      <% end %>
    </div>
    """
  end

  defp event_type_display(type) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.upcase()
  end

  defp event_color(:player_joined), do: "#10b981"
  defp event_color(:player_disconnected), do: "#ef4444"
  defp event_color(:player_reconnected), do: "#10b981"
  defp event_color(:game_started), do: "#3b82f6"
  defp event_color(:hand_locked_in), do: "#8b5cf6"
  defp event_color(:cards_discarded), do: "#f59e0b"
  defp event_color(:cards_drawn), do: "#06b6d4"
  defp event_color(:hands_revealed), do: "#ec4899"
  defp event_color(:round_completed), do: "#8b5cf6"
  defp event_color(:player_eliminated), do: "#dc2626"
  defp event_color(:player_ready), do: "#10b981"
  defp event_color(:round_started), do: "#3b82f6"
  defp event_color(:game_ended), do: "#f59e0b"
  defp event_color(_), do: "#6b7280"

  defp player_name(nil, _player_names, _current_player_id), do: "System"

  defp player_name(player_id, player_names, current_player_id) do
    name = Map.get(player_names, player_id, "Unknown")

    if player_id == current_player_id do
      "You (#{name})"
    else
      name
    end
  end

  defp format_timestamp(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_draw_reason(:after_discard), do: "after discard"
  defp format_draw_reason(:after_hand_played), do: "after playing hand"
  defp format_draw_reason(:round_start), do: "round start"
  defp format_draw_reason(reason), do: inspect(reason)

  defp format_hand_type(hand_type) do
    hand_type
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.upcase()
  end
end
