defmodule Oskol.Game.EventTest do
  use ExUnit.Case, async: true

  alias Oskol.Game.Event

  describe "new/5" do
    test "creates an event with all required fields" do
      event = Event.new("game-123", 1, :player_joined, "player-1", %{name: "Alice"})

      assert %Event{} = event
      assert is_binary(event.id)
      assert event.game_id == "game-123"
      assert event.sequence == 1
      assert event.type == :player_joined
      assert event.player_id == "player-1"
      assert event.data == %{name: "Alice"}
      assert %DateTime{} = event.timestamp
    end

    test "generates unique IDs for each event" do
      event1 = Event.new("game-1", 1, :player_joined)
      event2 = Event.new("game-1", 2, :player_joined)

      assert event1.id != event2.id
    end

    test "sets timestamp to current UTC time" do
      before = DateTime.utc_now()
      event = Event.new("game-1", 1, :player_joined)
      after_time = DateTime.utc_now()

      assert DateTime.compare(event.timestamp, before) in [:gt, :eq]
      assert DateTime.compare(event.timestamp, after_time) in [:lt, :eq]
    end

    test "allows nil player_id for system events" do
      event = Event.new("game-1", 1, :game_started, nil, %{})

      assert event.player_id == nil
    end

    test "defaults player_id to nil when not provided" do
      event = Event.new("game-1", 1, :game_started)

      assert event.player_id == nil
    end

    test "defaults data to empty map when not provided" do
      event = Event.new("game-1", 1, :round_started)

      assert event.data == %{}
    end

    test "supports all lobby event types" do
      types = [:player_joined, :player_disconnected, :player_reconnected, :game_started]

      for type <- types do
        event = Event.new("game-1", 1, type)
        assert event.type == type
      end
    end

    test "supports all playing event types" do
      types = [
        :hand_locked_in,
        :cards_discarded,
        :cards_drawn,
        :hands_revealed
      ]

      for type <- types do
        event = Event.new("game-1", 1, type)
        assert event.type == type
      end
    end

    test "supports all round event types" do
      types = [:round_completed, :player_eliminated, :player_ready, :round_started]

      for type <- types do
        event = Event.new("game-1", 1, type)
        assert event.type == type
      end
    end

    test "supports game end event type" do
      event = Event.new("game-1", 1, :game_ended)
      assert event.type == :game_ended
    end
  end
end
