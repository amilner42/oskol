//// A room's game rebuilt from its seed and action log, typed.
////
//// The rehydrator rebuilds a room through `instance.start` and the erased
//// `apply`/`expire`; this walks the very same log through the typed twins
//// of those calls (`instance.begin`, `step_taken`, `step_expire`), so a
//// consumer that needs the game's own state -- a post-game review -- sees
//// every step exactly as the room did, clocks and timeouts included.

import gamekit/clock.{type Control}
import gamekit/game.{type Game, type Seat}
import gamekit/instance.{type Running}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// One persisted step, as `game_actions` holds it.
pub type Entry {
  /// A payload applied for a player, `at_ms` after the instance started.
  Act(player_id: String, payload: Dynamic, at_ms: Int)
  /// The room resolved a clock that ran out.
  Expire(at_ms: Int)
}

/// Everything a replay needs: what started the game, then its log.
pub type Log {
  Log(
    format_id: String,
    seats: List(Seat),
    seed: Int,
    control: Control,
    entries: List(Entry),
  )
}

/// What one entry did.
pub type Transition(state, action) {
  Transition(
    /// The entry's position in the log.
    index: Int,
    before: state,
    after: state,
    /// Who acted: the entry's player, or None for an expiry.
    actor: Option(String),
    /// The action applied as itself. None for an expiry, and for an action
    /// a clock that had already run out pre-empted.
    action: Option(action),
    /// A clock ran out and was resolved during this entry.
    clock_ran_out: Bool,
  )
}

/// Fold every entry of the log, in order, from the started game. `from`
/// sees the state the game started in. An entry the game rejects fails the
/// replay, as it fails a rehydration: a log is only ever what was applied.
pub fn fold(
  definition: Game(state, action),
  log: Log,
  from: fn(state) -> acc,
  with: fn(acc, Transition(state, action)) -> acc,
) -> Result(#(acc, Running(state, action)), String) {
  use started <- result.try(instance.begin(
    definition,
    log.format_id,
    log.seats,
    log.seed,
    log.control,
    0,
  ))
  let initial = #(from(instance.running_state(started)), started)
  log.entries
  |> list.index_map(fn(entry, index) { #(index, entry) })
  |> list.try_fold(initial, fn(acc, indexed) {
    let #(folded, running) = acc
    let #(index, entry) = indexed
    let before = instance.running_state(running)
    use #(next, actor, action, ran_out) <- result.try(apply_entry(
      running,
      entry,
    ))
    let transition =
      Transition(
        index: index,
        before: before,
        after: instance.running_state(next),
        actor: actor,
        action: action,
        clock_ran_out: ran_out,
      )
    Ok(#(with(folded, transition), next))
  })
  |> result.map_error(fn(reason) { "Replay failed: " <> reason })
}

fn apply_entry(
  running: Running(state, action),
  entry: Entry,
) -> Result(
  #(Running(state, action), Option(String), Option(action), Bool),
  String,
) {
  case entry {
    Act(player_id, payload, at_ms) -> {
      let ran_out = clock.expired(instance.running_clocks(running), at_ms) != []
      use #(next, _events, taken) <- result.try(instance.step_taken(
        running,
        player_id,
        payload,
        at_ms,
      ))
      Ok(#(next, Some(player_id), taken, ran_out))
    }
    Expire(at_ms) ->
      case instance.step_expire(running, at_ms) {
        Some(#(next, _events)) -> Ok(#(next, None, None, True))
        // The room found nothing to resolve either (it logs what it ran)
        None -> Ok(#(running, None, None, False))
      }
  }
}
