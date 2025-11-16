defmodule Oskol.Game.Event do
  @moduledoc """
  Represents a single event in the game's event log.

  Events are immutable records of everything that happens in a game,
  allowing for complete game history, replay, and state reconstruction.

  Each event has:
  - `id`: Unique identifier for this event
  - `game_id`: Which game this event belongs to
  - `sequence`: Order within the game (1, 2, 3, ...)
  - `timestamp`: When the event occurred (UTC)
  - `type`: Atom representing the event type
  - `player_id`: Which player initiated the event (nil for system events)
  - `data`: Event-specific payload containing relevant information
  """

  defstruct [
    :id,
    :game_id,
    :sequence,
    :timestamp,
    :type,
    :player_id,
    :data
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          game_id: String.t(),
          sequence: integer(),
          timestamp: DateTime.t(),
          type: event_type(),
          player_id: String.t() | nil,
          data: map()
        }

  @type event_type ::
          # Lobby events
          :player_joined
          | :player_disconnected
          | :player_reconnected
          | :game_started
          # Playing events
          | :hand_locked_in
          | :hand_unlocked
          | :cards_discarded
          | :cards_drawn
          | :hands_revealed
          # Round events
          | :round_completed
          | :player_eliminated
          | :player_ready
          | :round_started
          # End game
          | :game_ended

  @doc """
  Creates a new event with the given parameters.

  The `id` is automatically generated using Nanoid.
  The `timestamp` is automatically set to the current UTC time.

  ## Examples

      iex> event = Event.new("game-123", 1, :player_joined, "player-1", %{name: "Alice"})
      iex> event.type
      :player_joined
      iex> event.sequence
      1
  """
  def new(game_id, sequence, type, player_id \\ nil, data \\ %{}) do
    %__MODULE__{
      id: Nanoid.generate(),
      game_id: game_id,
      sequence: sequence,
      timestamp: DateTime.utc_now(),
      type: type,
      player_id: player_id,
      data: data
    }
  end
end
