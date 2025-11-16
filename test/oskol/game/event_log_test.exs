defmodule Oskol.Game.EventLogTest do
  use ExUnit.Case, async: true

  alias Oskol.Game.EventLog
  alias Oskol.Game.Event

  describe "new/0" do
    test "creates an empty event log" do
      log = EventLog.new()

      assert %EventLog{} = log
      assert log.events == []
      assert log.next_sequence == 1
    end
  end

  describe "append/5" do
    test "appends an event to the log" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1", %{name: "Alice"})

      events = EventLog.get_all(log)
      assert length(events) == 1
      assert hd(events).type == :player_joined
    end

    test "assigns sequential sequence numbers" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")
      log = EventLog.append(log, "game-1", :game_started)

      events = EventLog.get_all(log)
      assert Enum.at(events, 0).sequence == 1
      assert Enum.at(events, 1).sequence == 2
      assert Enum.at(events, 2).sequence == 3
    end

    test "increments next_sequence counter" do
      log = EventLog.new()
      assert log.next_sequence == 1

      log = EventLog.append(log, "game-1", :player_joined)
      assert log.next_sequence == 2

      log = EventLog.append(log, "game-1", :game_started)
      assert log.next_sequence == 3
    end

    test "returns updated log" do
      log = EventLog.new()
      updated_log = EventLog.append(log, "game-1", :player_joined)

      assert %EventLog{} = updated_log
      assert log != updated_log
    end
  end

  describe "append_many/3" do
    test "appends multiple events in order" do
      log = EventLog.new()

      events_data = [
        {:player_joined, "p1", %{name: "Alice"}},
        {:player_joined, "p2", %{name: "Bob"}},
        {:game_started, nil, %{}}
      ]

      log = EventLog.append_many(log, "game-1", events_data)

      events = EventLog.get_all(log)
      assert length(events) == 3
      assert Enum.at(events, 0).type == :player_joined
      assert Enum.at(events, 1).type == :player_joined
      assert Enum.at(events, 2).type == :game_started
    end

    test "assigns sequential sequence numbers to batch" do
      log = EventLog.new()

      events_data = [
        {:player_joined, "p1", %{}},
        {:player_joined, "p2", %{}},
        {:game_started, nil, %{}}
      ]

      log = EventLog.append_many(log, "game-1", events_data)

      events = EventLog.get_all(log)
      assert Enum.at(events, 0).sequence == 1
      assert Enum.at(events, 1).sequence == 2
      assert Enum.at(events, 2).sequence == 3
    end
  end

  describe "get_all/1" do
    test "returns empty list for new log" do
      log = EventLog.new()
      assert EventLog.get_all(log) == []
    end

    test "returns events in chronological order" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")
      log = EventLog.append(log, "game-1", :game_started)

      events = EventLog.get_all(log)
      assert length(events) == 3
      assert Enum.at(events, 0).sequence == 1
      assert Enum.at(events, 1).sequence == 2
      assert Enum.at(events, 2).sequence == 3
    end
  end

  describe "get_since/2" do
    setup do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")
      log = EventLog.append(log, "game-1", :game_started)
      log = EventLog.append(log, "game-1", :hand_locked_in, "p1")
      log = EventLog.append(log, "game-1", :hand_locked_in, "p2")

      {:ok, log: log}
    end

    test "returns events from specified sequence onward", %{log: log} do
      events = EventLog.get_since(log, 3)

      assert length(events) == 3
      assert Enum.at(events, 0).sequence == 3
      assert Enum.at(events, 1).sequence == 4
      assert Enum.at(events, 2).sequence == 5
    end

    test "returns empty list when sequence is beyond log", %{log: log} do
      events = EventLog.get_since(log, 100)
      assert events == []
    end

    test "includes event at exact sequence", %{log: log} do
      events = EventLog.get_since(log, 1)
      assert length(events) == 5
      assert hd(events).sequence == 1
    end
  end

  describe "get_by_type/2" do
    setup do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")
      log = EventLog.append(log, "game-1", :game_started)
      log = EventLog.append(log, "game-1", :cards_drawn, "p1")
      log = EventLog.append(log, "game-1", :cards_drawn, "p2")

      {:ok, log: log}
    end

    test "returns only events of specified type", %{log: log} do
      events = EventLog.get_by_type(log, :player_joined)

      assert length(events) == 2
      assert Enum.all?(events, fn e -> e.type == :player_joined end)
    end

    test "returns empty list when type not found", %{log: log} do
      events = EventLog.get_by_type(log, :game_ended)
      assert events == []
    end

    test "maintains chronological order", %{log: log} do
      events = EventLog.get_by_type(log, :cards_drawn)

      assert length(events) == 2
      assert Enum.at(events, 0).sequence < Enum.at(events, 1).sequence
    end
  end

  describe "get_by_player/2" do
    setup do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")
      log = EventLog.append(log, "game-1", :game_started, nil)
      log = EventLog.append(log, "game-1", :hand_locked_in, "p1")
      log = EventLog.append(log, "game-1", :hand_locked_in, "p2")

      {:ok, log: log}
    end

    test "returns only events for specified player", %{log: log} do
      events = EventLog.get_by_player(log, "p1")

      assert length(events) == 2
      assert Enum.all?(events, fn e -> e.player_id == "p1" end)
    end

    test "excludes system events (nil player_id)", %{log: log} do
      events = EventLog.get_by_player(log, "p1")

      refute Enum.any?(events, fn e -> e.player_id == nil end)
    end

    test "returns empty list for player with no events", %{log: log} do
      events = EventLog.get_by_player(log, "p999")
      assert events == []
    end
  end

  describe "get_latest/2" do
    setup do
      log = EventLog.new()

      log =
        Enum.reduce(1..15, log, fn i, acc ->
          EventLog.append(acc, "game-1", :cards_drawn, "p1")
        end)

      {:ok, log: log}
    end

    test "returns last N events", %{log: log} do
      events = EventLog.get_latest(log, 5)

      assert length(events) == 5
      assert Enum.at(events, 0).sequence == 11
      assert Enum.at(events, 4).sequence == 15
    end

    test "defaults to 10 events", %{log: log} do
      events = EventLog.get_latest(log)
      assert length(events) == 10
    end

    test "returns all events if count exceeds log size" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :player_joined, "p2")

      events = EventLog.get_latest(log, 100)
      assert length(events) == 2
    end

    test "maintains chronological order", %{log: log} do
      events = EventLog.get_latest(log, 5)
      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences)
    end
  end

  describe "count/1" do
    test "returns 0 for new log" do
      log = EventLog.new()
      assert EventLog.count(log) == 0
    end

    test "returns correct count after appends" do
      log = EventLog.new()
      assert EventLog.count(log) == 0

      log = EventLog.append(log, "game-1", :player_joined)
      assert EventLog.count(log) == 1

      log = EventLog.append(log, "game-1", :player_joined)
      assert EventLog.count(log) == 2
    end
  end

  describe "get_last/1" do
    test "returns nil for empty log" do
      log = EventLog.new()
      assert EventLog.get_last(log) == nil
    end

    test "returns most recent event" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      log = EventLog.append(log, "game-1", :game_started)

      last = EventLog.get_last(log)
      assert last.type == :game_started
      assert last.sequence == 2
    end
  end

  describe "get_by_time_range/3" do
    test "returns events within time range" do
      log = EventLog.new()

      # Create events with slight delays to ensure different timestamps
      log = EventLog.append(log, "game-1", :player_joined, "p1")
      Process.sleep(10)

      middle_time = DateTime.utc_now()
      Process.sleep(10)

      log = EventLog.append(log, "game-1", :player_joined, "p2")
      Process.sleep(10)

      end_time = DateTime.utc_now()

      events = EventLog.get_by_time_range(log, middle_time, end_time)

      # Should include the second player_joined event
      assert length(events) >= 1
    end

    test "returns empty list when no events in range" do
      log = EventLog.new()
      log = EventLog.append(log, "game-1", :player_joined)

      future_start = DateTime.add(DateTime.utc_now(), 1000, :second)
      future_end = DateTime.add(DateTime.utc_now(), 2000, :second)

      events = EventLog.get_by_time_range(log, future_start, future_end)
      assert events == []
    end
  end
end
