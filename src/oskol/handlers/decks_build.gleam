//// Building the universal decks: the operator's task that asks the engine
//// about every position of a deck and writes the answers down
//// (`mix oskol.decks.build`, `Oskol.Release.build_decks/1`).
////
//// Engine time is the whole cost, so the run is careful with it:
////
////   * **Only what is missing is asked.** A position is the question it asks
////     (the same key every puzzle has), so a deck's members are read first
////     and a position already in it is never asked again. A second run finds
////     nothing and writes nothing.
////   * **A dry run asks nobody.** Without `write` it counts what a real run
////     would ask and stops there.
////   * **Nothing half-trusted is stored.** A deck has no game behind it to
////     ask again from, and a player's answer is graded against what is
////     written, so an answer that is not complete is counted as a failure and
////     left out (`openings.answer`); the next run asks for it again.
////   * **Each batch is written as it lands**, so an engine that falls over
////     halfway through keeps everything it had already answered.
////
//// Replies are asked against the best opening play *as stored*, which is why
//// the openings are built first and why a reply waits for its opening.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/puzzles.{type NewPuzzle}
import oskol/core/ctx.{type Ctx}
import oskol/practice/decks
import oskol/practice/openings
import oskol/puzzles as puzzle
import oskol/reviews/report

/// What one deck's run found and did.
pub type Report {
  Report(
    deck: String,
    /// Positions the deck should have.
    positions: Int,
    /// Of those, already in the deck before this run.
    had: Int,
    /// Asked of the engine by this run (0 on a dry run).
    asked: Int,
    /// Positions this run added to the deck.
    added: Int,
    /// Positions that could not be asked yet: a reply whose opening is not
    /// stored. Only a dry run of a fresh database has any.
    waiting: Int,
    /// Why a position or a batch was not written, one line each.
    failures: List(String),
  )
}

pub fn run(ctx: Ctx, write: Bool) -> List(Report) {
  let #(opening_report, answers) = build_openings(ctx, write)
  let reply_report = build_replies(ctx, write, answers)
  [opening_report, reply_report]
}

/// One line per deck, for the operator's terminal.
pub fn describe(reports: List(Report)) -> String {
  reports
  |> list.map(fn(r) {
    string.join(
      [
        r.deck <> ":",
        int.to_string(r.positions) <> " positions,",
        int.to_string(r.had) <> " already in,",
        int.to_string(r.asked) <> " asked,",
        int.to_string(r.added) <> " added,",
        int.to_string(r.waiting) <> " waiting on their opening,",
        int.to_string(list.length(r.failures)) <> " failed",
      ],
      " ",
    )
    <> case r.failures {
      [] -> ""
      failures -> "\n  " <> string.join(failures, "\n  ")
    }
  })
  |> string.join("\n")
}

// ---------- What a deck already holds ----------

/// The deck's members by question key, each with its stored answer when it
/// can be read.
fn held(ctx: Ctx, deck: String) -> Dict(String, Option(puzzle.Answer)) {
  ctx.decks.members(deck)
  |> list.filter_map(fn(m) {
    use q <- result.try(
      puzzle.question_from_json(m.question_json) |> result.replace_error(Nil),
    )
    let answer =
      ctx.puzzles.get(m.puzzle_id)
      |> option.to_result(Nil)
      |> result.try(fn(stored) {
        puzzle.answer_from_json(stored.answer_json) |> result.replace_error(Nil)
      })
      |> option.from_result
    Ok(#(puzzle.key(q), answer))
  })
  |> dict.from_list
}

// ---------- The openings ----------

/// The openings, and the answer for each roll that has one now (stored
/// before, or asked by this run) -- what the replies are built against.
fn build_openings(
  ctx: Ctx,
  write: Bool,
) -> #(Report, List(#(Int, #(Int, Int), puzzle.Answer))) {
  let have = held(ctx, decks.openings_id)
  let rolls = list.index_map(openings.opening_rolls(), fn(r, i) { #(i + 1, r) })
  let start = openings.start()

  let results =
    list.map(rolls, fn(entry) {
      let #(n, roll) = entry
      let q = openings.question(start, roll)
      case dict.get(have, puzzle.key(q)) {
        Ok(Some(answer)) -> Stored(n, roll, answer)
        Ok(None) ->
          Failed(
            "opening "
            <> openings.roll_name(roll)
            <> ": its stored answer does not read",
          )
        Error(Nil) ->
          case write {
            False -> Missing
            True ->
              case ask(ctx, start, [#(0, roll)]) {
                Ok(#([answer], levels)) ->
                  Asked(n, roll, answer, openings.new_puzzle(q, answer, levels))
                Ok(_) ->
                  Failed(
                    "opening "
                    <> openings.roll_name(roll)
                    <> ": the engine answered the wrong number of turns",
                  )
                Error(why) ->
                  Failed("opening " <> openings.roll_name(roll) <> ": " <> why)
              }
          }
      }
    })

  let new =
    list.filter_map(results, fn(r) {
      case r {
        Asked(n, _, _, p) -> Ok(#(p, openings.opening_position(n)))
        _ -> Error(Nil)
      }
    })
  let #(added, store_failure) = store(ctx, decks.openings_id, new)

  let answers =
    list.filter_map(results, fn(r) {
      case r {
        Stored(n, roll, answer) -> Ok(#(n, roll, answer))
        // Written, or on a dry run nothing is asked, so this is a write.
        Asked(n, roll, answer, _) if store_failure == None ->
          Ok(#(n, roll, answer))
        _ -> Error(Nil)
      }
    })

  #(
    Report(
      deck: decks.openings_id,
      positions: list.length(rolls),
      had: dict.size(have),
      asked: case write {
        True ->
          list.length(rolls)
          - count(rolls, fn(r) {
            dict.has_key(have, puzzle.key(openings.question(start, r.1)))
          })
        False -> 0
      },
      added: added,
      waiting: 0,
      failures: list.flatten([
        failures(results),
        maybe(store_failure),
        case write {
          True -> []
          False ->
            case count(results, fn(r) { r == Missing }) {
              0 -> []
              n -> ["dry run: " <> int.to_string(n) <> " to ask"]
            }
        },
      ]),
    ),
    answers,
  )
}

type Outcome {
  Stored(n: Int, roll: #(Int, Int), answer: puzzle.Answer)
  Asked(n: Int, roll: #(Int, Int), answer: puzzle.Answer, puzzle: NewPuzzle)
  Missing
  Failed(String)
}

fn failures(results: List(Outcome)) -> List(String) {
  list.filter_map(results, fn(r) {
    case r {
      Failed(why) -> Ok(why)
      _ -> Error(Nil)
    }
  })
}

fn count(items: List(a), keep: fn(a) -> Bool) -> Int {
  list.length(list.filter(items, keep))
}

// ---------- The replies ----------

fn build_replies(
  ctx: Ctx,
  write: Bool,
  openings_answered: List(#(Int, #(Int, Int), puzzle.Answer)),
) -> Report {
  let have = held(ctx, decks.replies_id)
  let rolls = list.index_map(openings.all_rolls(), fn(r, i) { #(i + 1, r) })
  let total = list.length(openings.opening_rolls()) * list.length(rolls)
  let waiting =
    { list.length(openings.opening_rolls()) - list.length(openings_answered) }
    * list.length(rolls)

  let batches =
    list.map(openings_answered, fn(opening) {
      let #(n, roll, answer) = opening
      case openings.best_board(answer) {
        Error(Nil) ->
          Batch(0, 0, 0, [
            "replies to "
            <> openings.roll_name(roll)
            <> ": the opening has no best play",
          ])
        Ok(best) -> {
          let board = openings.after(best)
          let missing =
            list.filter(rolls, fn(r) {
              !dict.has_key(have, puzzle.key(openings.question(board, r.1)))
            })
          case write, missing {
            _, [] -> Batch(0, 0, 0, [])
            False, _ -> Batch(list.length(missing), 0, 0, [])
            True, _ -> reply_batch(ctx, n, roll, board, missing)
          }
        }
      }
    })

  let sum = fn(pick: fn(Batch) -> Int) { int.sum(list.map(batches, pick)) }
  let to_ask = sum(fn(b) { b.to_ask })
  Report(
    deck: decks.replies_id,
    positions: total,
    had: dict.size(have),
    asked: sum(fn(b) { b.asked }),
    added: sum(fn(b) { b.added }),
    waiting: waiting,
    failures: list.flatten([
      list.flat_map(batches, fn(b) { b.failures }),
      case write, to_ask {
        False, n if n > 0 -> ["dry run: " <> int.to_string(n) <> " to ask"]
        _, _ -> []
      },
    ]),
  )
}

type Batch {
  Batch(to_ask: Int, asked: Int, added: Int, failures: List(String))
}

/// The missing replies to one opening, in one request: they share a board,
/// and the engine answers each turn on its own.
fn reply_batch(
  ctx: Ctx,
  opening: Int,
  opening_roll: #(Int, Int),
  board: List(Int),
  missing: List(#(Int, #(Int, Int))),
) -> Batch {
  // Each reply is its game's second turn; the index is still unique within
  // the request, as the engine files each answer under the index it was
  // given.
  let asked = list.index_map(missing, fn(r, i) { #(i + 1, r.1) })
  case ask(ctx, board, asked) {
    Error(why) ->
      Batch(0, list.length(missing), 0, [
        "replies to " <> openings.roll_name(opening_roll) <> ": " <> why,
      ])
    Ok(#(answers, levels)) ->
      case list.strict_zip(missing, answers) {
        Error(Nil) ->
          Batch(0, list.length(missing), 0, [
            "replies to "
            <> openings.roll_name(opening_roll)
            <> ": the engine answered the wrong number of turns",
          ])
        Ok(pairs) -> {
          let entries =
            list.map(pairs, fn(pair) {
              let #(#(i, roll), answer) = pair
              #(
                openings.new_puzzle(
                  openings.question(board, roll),
                  answer,
                  levels,
                ),
                openings.reply_position(opening, i),
              )
            })
          let #(added, failure) = store(ctx, decks.replies_id, entries)
          Batch(0, list.length(missing), added, maybe(failure))
        }
      }
  }
}

// ---------- Asking, and writing ----------

/// Ask the engine about some rolls from one board, and hand back an answer
/// per roll -- or the reason the whole request cannot be trusted. A single
/// position that comes back incomplete fails the request: it is one board,
/// asked once, and a partial write would leave the deck with a hole the next
/// run has to find anyway.
fn ask(
  ctx: Ctx,
  board: List(Int),
  rolls: List(#(Int, #(Int, Int))),
) -> Result(#(List(puzzle.Answer), Option(report.Levels)), String) {
  use turns <- result.try(
    list.try_map(rolls, fn(r) {
      openings.turn(board, r.1) |> result.map(fn(t) { #(r.0, t) })
    }),
  )
  use body <- result.try(ctx.analysis.review(openings.request(turns)))
  use review <- result.try(report.parse(body))
  use answers <- result.try(list.try_map(review.turns, openings.answer))
  Ok(#(answers, review.levels))
}

/// Write a batch, if there is one. The members it added, and why it failed
/// when it did.
fn store(
  ctx: Ctx,
  deck: String,
  entries: List(#(NewPuzzle, Int)),
) -> #(Int, Option(String)) {
  case entries {
    [] -> #(0, None)
    _ ->
      case ctx.decks.store(deck, entries) {
        Ok(stored) -> #(stored.members, None)
        Error(why) -> #(0, Some(deck <> ": the write failed: " <> why))
      }
  }
}

fn maybe(value: Option(a)) -> List(a) {
  case value {
    Some(v) -> [v]
    None -> []
  }
}
