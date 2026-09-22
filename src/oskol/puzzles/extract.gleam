//// Which turns of a graded game are puzzles, and what each one stores.
////
//// A mistake is any decision that gave up 0.02 or more -- the site's
//// doubtful band and everything worse -- and there are three kinds: the
//// checker play, the doubler's call, and the responder's answer to a
//// double. A turn can be two of them at once (a cube mistake and a checker
//// mistake are two puzzles).
////
//// This runs exactly where the engine's answer and the game's own turns
//// are both in memory: the review job (`oskol/handlers/reviews`), once. The
//// board a decision was made *on* is nowhere else -- a stored review keeps
//// only the boards each candidate move leaves -- so nothing downstream can
//// rebuild a puzzle, and no read path ever tries.
////
//// Not a puzzle: a forced play, a roll that could play nothing, a "no
//// double" the engine grades where no double could have been offered (the
//// opening roll, a cube the mover does not hold, the Crawford game -- the
//// same rule the replay draws its cube verdicts by), and, for now, the
//// checker play of a turn whose double was taken: the engine evaluates
//// those on the cube as it stood *before* the offer
//// (`bg-analysis-post-take-context`). Those last ones are still written
//// down, as a source with a reason and no puzzle, so a repair can find and
//// count them once the engine is fixed.

import backgammon/analysis.{type GameTurns, type Turn, Took}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oskol/caps/puzzles.{type NewPuzzle, type NewSource, NewPuzzle, NewSource}
import oskol/puzzles as puzzle
import oskol/reviews/report.{type Review, type TurnReview, Moved}

/// A turn whose checker play the engine graded on the wrong cube.
pub const post_take_reason = "post_take_cube"

/// Everything one graded game writes: the puzzles it found and the sources
/// that point at them, ready for `caps/puzzles.store`. Error when the
/// engine's answer does not line up with the game's own turns, which is the
/// same check the rendered report makes.
pub fn from_review(
  g: GameTurns,
  seats: List(report.Seat),
  review: Review,
) -> Result(#(List(NewPuzzle), List(NewSource)), String) {
  use pairs <- result.try(
    list.strict_zip(g.turns, review.turns)
    |> result.replace_error("The review does not match the game"),
  )
  let by = evaluated_by(review)
  let found =
    pairs
    |> list.index_map(fn(pair, i) { #(pair.0, pair.1, i + 1) })
    |> list.flat_map(fn(entry) {
      let #(turn, graded, number) = entry
      list.flatten([
        move_puzzle(g, turn, graded, number),
        cube_puzzles(g, turn, graded, number, seats),
      ])
    })
  Ok(#(
    // Two sources of one puzzle within a game (the same position twice)
    // write the puzzle once.
    found
      |> list.filter_map(fn(f) { option.to_result(f.0, Nil) })
      |> unique_by_key([])
      |> list.map(fn(q) { new_puzzle(q.0, q.1, by) }),
    list.map(found, fn(f) { f.1 }),
  ))
}

/// A decision worth storing: the question and answer to write (None when
/// the turn is skipped), and the source row that records whose it was.
type Found =
  #(Option(#(puzzle.Question, puzzle.Answer)), NewSource)

fn unique_by_key(
  found: List(#(puzzle.Question, puzzle.Answer)),
  seen: List(String),
) -> List(#(puzzle.Question, puzzle.Answer)) {
  case found {
    [] -> []
    [first, ..rest] -> {
      let key = puzzle.key(first.0)
      case list.contains(seen, key) {
        True -> unique_by_key(rest, seen)
        False -> [first, ..unique_by_key(rest, [key, ..seen])]
      }
    }
  }
}

fn new_puzzle(
  question: puzzle.Question,
  answer: puzzle.Answer,
  by: puzzle.EvaluatedBy,
) -> NewPuzzle {
  NewPuzzle(
    key: puzzle.key(question),
    ids: puzzle.ids(question),
    kind: puzzle.kind_name(question.kind),
    question_json: json.to_string(puzzle.question_json(question)),
    answer_json: json.to_string(puzzle.answer_json(answer)),
    evaluated_by_json: json.to_string(puzzle.evaluated_by_json(by)),
  )
}

fn evaluated_by(review: Review) -> puzzle.EvaluatedBy {
  case review.levels {
    Some(report.Levels(moves, cube)) ->
      puzzle.EvaluatedBy(Some(moves), Some(cube))
    None -> puzzle.EvaluatedBy(None, None)
  }
}

// ---------- The checker play ----------

fn move_puzzle(
  g: GameTurns,
  turn: Turn,
  graded: TurnReview,
  number: Int,
) -> List(Found) {
  case graded.move, turn.dice {
    Some(Moved(played, _best, top, results, n_legal, forced, error, grade)),
      Some(dice)
      if !forced
    ->
      case puzzle.is_mistake(error) && !analysis.danced(turn) {
        False -> []
        True -> {
          let source = fn(key) {
            NewSource(
              key: key,
              game_number: g.number,
              turn: number,
              kind: "move",
              seat: turn.player,
              player_id: turn.player_id,
              played: played.notation,
              equity_lost: error,
              grade: grade,
              skipped_reason: case key {
                Some(_) -> None
                None -> Some(post_take_reason)
              },
            )
          }
          case turn.double == Some(Took) {
            // The engine graded this play on the cube as it stood before
            // the double it followed. Recorded, not asked.
            True -> [#(None, source(None))]
            False -> {
              let question =
                puzzle.question_of(
                  puzzle.Move,
                  turn.position,
                  Some(dice),
                  g.jacoby,
                )
              let answer = move_answer(played, top, results, n_legal)
              [#(Some(#(question, answer)), source(Some(puzzle.key(question))))]
            }
          }
        }
      }
    _, _ -> []
  }
}

/// Every legal play the engine evaluated when it sent them, the five it
/// described when it did not; the top five plus the move that was played,
/// with everything a reveal shows.
fn move_answer(
  played: report.Candidate,
  top: List(report.Candidate),
  results: List(report.MoveResult),
  n_legal: Int,
) -> puzzle.Answer {
  let candidates =
    [played, ..top]
    |> list.sort(fn(a, b) { int.compare(a.rank, b.rank) })
    |> dedupe_ranks([])
    |> list.map(candidate)
  let complete = results != []
  let outcomes = case complete {
    True ->
      list.map(results, fn(r) {
        puzzle.Outcome(board: r.board, equity_lost: lost(r.equity_diff))
      })
    False ->
      list.map(candidates, fn(c) {
        puzzle.Outcome(board: c.board, equity_lost: c.equity_lost)
      })
  }
  puzzle.MoveAnswer(
    outcomes: outcomes,
    complete: complete,
    n_legal: n_legal,
    candidates: candidates,
  )
}

fn dedupe_ranks(
  candidates: List(report.Candidate),
  seen: List(Int),
) -> List(report.Candidate) {
  case candidates {
    [] -> []
    [first, ..rest] ->
      case list.contains(seen, first.rank) {
        True -> dedupe_ranks(rest, seen)
        False -> [first, ..dedupe_ranks(rest, [first.rank, ..seen])]
      }
  }
}

fn candidate(c: report.Candidate) -> puzzle.Candidate {
  puzzle.Candidate(
    rank: c.rank,
    notation: c.notation,
    equity: c.equity,
    equity_lost: lost(c.equity_diff),
    board: c.board,
    probs: probs(c.probs),
  )
}

/// The engine's diff is best-relative and negative for a worse play.
fn lost(equity_diff: Float) -> Float {
  case equity_diff <. 0.0 {
    True -> 0.0 -. equity_diff
    False -> 0.0
  }
}

fn probs(p: report.Probs) -> puzzle.Probs {
  puzzle.Probs(
    win: p.win,
    gammon_win: p.gammon_win,
    backgammon_win: p.backgammon_win,
    gammon_loss: p.gammon_loss,
    backgammon_loss: p.backgammon_loss,
  )
}

// ---------- The cube ----------

fn cube_puzzles(
  g: GameTurns,
  turn: Turn,
  graded: TurnReview,
  number: Int,
  seats: List(report.Seat),
) -> List(Found) {
  case graded.cube {
    None -> []
    Some(cube) ->
      case gradeable(cube, turn, number) {
        False -> []
        True -> {
          let answer = cube_answer(cube)
          let doubler = case puzzle.is_mistake(cube.doubler.error) {
            False -> []
            True -> {
              let question =
                puzzle.question_of(puzzle.Double, turn.position, None, g.jacoby)
              [
                #(
                  Some(#(question, answer)),
                  NewSource(
                    key: Some(puzzle.key(question)),
                    game_number: g.number,
                    turn: number,
                    kind: "double",
                    seat: turn.player,
                    player_id: turn.player_id,
                    played: cube.action,
                    equity_lost: cube.doubler.error,
                    grade: cube.doubler.grade,
                    skipped_reason: None,
                  ),
                ),
              ]
            }
          }
          let taker = case cube.taker, turn.double {
            Some(verdict), Some(_) ->
              case puzzle.is_mistake(verdict.error) {
                False -> []
                True -> {
                  let question =
                    puzzle.question_of(
                      puzzle.Take,
                      turn.position,
                      None,
                      g.jacoby,
                    )
                  // The responder's seat, not the mover's: the answer to a
                  // double is the other player's decision.
                  let seat = 1 - turn.player
                  [
                    #(
                      Some(#(question, answer)),
                      NewSource(
                        key: Some(puzzle.key(question)),
                        game_number: g.number,
                        turn: number,
                        kind: "take",
                        seat: seat,
                        player_id: player_id_at(seats, seat),
                        played: option.unwrap(cube.response, ""),
                        equity_lost: verdict.error,
                        grade: verdict.grade,
                        skipped_reason: None,
                      ),
                    ),
                  ]
                }
              }
            _, _ -> []
          }
          list.flatten([doubler, taker])
        }
      }
  }
}

/// The replay's rule, and the same one: the engine grades "no double" on
/// every turn, the opening roll and a cube the mover cannot turn included.
/// A verdict on a double that could not have been offered is nothing to
/// ask anybody about.
fn gradeable(cube: report.CubeReview, turn: Turn, number: Int) -> Bool {
  !{
    cube.action == "no_double"
    && { number == 1 || !analysis.engine_can_double(turn.position) }
  }
}

fn cube_answer(cube: report.CubeReview) -> puzzle.Answer {
  let optimal = puzzle.optimal_from_engine(cube.optimal)
  puzzle.CubeAnswer(
    no_double: cube.no_double,
    double_take: cube.double_take,
    double_pass: cube.double_pass,
    probs: option.map(cube.probs, probs),
    optimal: optimal,
    too_good: puzzle.too_good(optimal, cube.no_double, cube.double_pass),
  )
}

fn player_id_at(seats: List(report.Seat), index: Int) -> String {
  case list.drop(seats, index) {
    [seat, ..] -> seat.player_id
    [] -> ""
  }
}
