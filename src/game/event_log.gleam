import gleam/list
import game/player.{type PlayerId}
import poker/card.{type Card}
import poker/hand.{type HandType}
import gleam/dict

/// Hand result for events (matches state.HandResult)
pub type HandResult {
  HandResult(
    hand: List(Card),
    hand_type: HandType,
    score: Int,
    total_chips: Int,
    total_multiplier: Int,
  )
}

/// Game events - things that happened as a result of an action
pub type GameEvent {
  CardsDiscarded(PlayerId, List(Card), List(Card))
  HandLockedIn(PlayerId, List(Card))
  HandsResolved(dict.Dict(PlayerId, HandResult), Bool)
  RoundEnded(List(PlayerId), Bool)
  GameOver(PlayerId)
  NewRoundStarted(Int)
  PlayerReady(PlayerId)
  HandUpgraded(PlayerId, HandType, Int)
  ActionError(String)
}

/// Event log - stores all game events in chronological order
pub type EventLog {
  EventLog(events: List(GameEvent), next_sequence: Int)
}

/// Create a new empty event log
pub fn new() -> EventLog {
  EventLog(events: [], next_sequence: 1)
}

/// Append a single event to the log
pub fn append(log: EventLog, event: GameEvent) -> EventLog {
  EventLog(
    events: [event, ..log.events],
    next_sequence: log.next_sequence + 1,
  )
}

/// Append multiple events to the log
pub fn append_many(log: EventLog, events: List(GameEvent)) -> EventLog {
  list.fold(events, log, fn(acc, event) { append(acc, event) })
}

/// Get all events in chronological order (oldest first)
pub fn get_all(log: EventLog) -> List(GameEvent) {
  list.reverse(log.events)
}

/// Get the most recent N events in chronological order
pub fn get_latest(log: EventLog, count: Int) -> List(GameEvent) {
  log.events
  |> list.take(count)
  |> list.reverse()
}

/// Get events since a specific sequence number
pub fn get_since(log: EventLog, sequence: Int) -> List(GameEvent) {
  let events_to_skip = log.next_sequence - sequence - 1
  log.events
  |> list.drop(events_to_skip)
  |> list.reverse()
}

/// Get the total number of events in the log
pub fn count(log: EventLog) -> Int {
  list.length(log.events)
}

/// Get the last event in the log, if any
pub fn get_last(log: EventLog) -> Result(GameEvent, Nil) {
  list.first(log.events)
}
