//// The puzzle pages, as JSON:
////
////     GET  /papi/puzzles/:id                      the question and the
////                                                 legal moves, never the
////                                                 answer
////     GET  /papi/puzzles/:id/tree?node=           one level of a tree too
////                                                 big to send whole
////     POST /papi/puzzles/:id/attempts             grade it, reveal it, and
////                                                 move the ladder once
////     POST /papi/puzzles/:id/attempts/:key/outcome  the player's override
////     GET  /papi/puzzles/:id/mine                 the memory line, for a
////                                                 player of the game it
////                                                 came from
////     GET  /papi/games/:slug/rooms/:id/puzzles?game=n
////                                                 that game's mistakes,
////                                                 for the seat you hold
////
//// **A puzzle is open.** It is a position and a question; it names nobody,
//// says nothing about the game it came from, and marks nothing as the move
//// that was played. Anybody with the link may try it, and trying it costs
//// the engine nothing -- every answer was worked out once, when the game was
//// graded, and is read back from the row.
////
//// **One grading rule.** `oskol/puzzles/grade` decides, and the guest on a
//// shared link and the account whose deck is watching get the same verdict
//// out of it. What differs is only what is remembered: a guest's attempt is
//// written nowhere.
////
//// **One scheduled answer per opportunity.** A signed-in player whose deck
//// holds the puzzle writes an attempt row first, keyed by the id their own
//// client minted, and the ladder moves only when that row is new *and* the
//// card is due. A review always pushes the card's due date into the future,
//// so the second answer -- another tab, a retry, "let me see that again" --
//// finds nothing due and changes nothing. The player may still override the
//// grade afterwards, and an override replaces the review rather than
//// stacking on it.

import backgammon/analysis
import backgammon/board.{type Board, type Move, Move, White}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oskol/caps/practice.{
  type Card, type Outcome, Active, Again, Known, New, Partial,
  Pass as PassOutcome, Suspended,
}
import oskol/caps/puzzles as caps
import oskol/core/ctx.{type Ctx}
import oskol/core/envelope
import oskol/core/error.{type ApiError}
import oskol/core/raw
import oskol/core/session.{type Session}
import oskol/practice/deck
import oskol/puzzles.{
  type Answer, type Candidate, type Question, CubeAnswer, Double,
  Move as MoveKind, MoveAnswer, Mover, Opponent, Question, Take,
}
import oskol/puzzles/grade.{type Verdict, Fail, Hold, Pass, Unknown}
import oskol/puzzles/tree
import oskol/rooms/seat

/// Nothing answers to that id. The same sentence for a puzzle that is not
/// there and one whose question will not read back, because neither is
/// something a visitor can do anything about.
pub const not_found_message = "No such puzzle"

pub const no_memory_message = "You were not in the game that puzzle came from"

pub const no_game_message = "No puzzles for that game"

pub const bad_move_message = "That is not a legal way to play the roll"

pub const bad_band_message = "That is not one of the five answers"

pub const no_key_message = "That answer arrived without a key"

pub const not_yours_message = "That answer is not yours"

pub const nothing_to_amend_message = "There is nothing to change about that answer"

/// The wire budget for a whole move tree. Past it a puzzle sends the root
/// alone and the page asks for each level as it reaches it: one round trip
/// per checker on the few positions that need it, rather than a hundred
/// kilobytes on every phone for the ones that do not.
pub const tree_byte_budget = 100_000

/// How many positions the build may examine before it gives up and serves
/// the root alone. The bytes are what the page pays, but they are not what
/// bounds the *work*: whether a turn's longest play is three dice or four
/// depends on every position it can reach, so a tree that is going to be
/// too big is too big before the first node is written down. Measured on
/// the contrived spread-out doubles the tree contract was frozen against:
/// giving up at 260 positions costs 61 ms, at 400 it costs 120 ms, and the
/// budget is 100. A tree that fits inside 260 positions is at most about
/// 114 KB, so the byte budget still has the last word.
pub const tree_node_budget = 260

/// Levels come back after these many days (`oskol/practice/deck` owns the
/// ladder itself); a day is this many milliseconds, which is what an
/// unknown answer is pushed out by.
const day_ms = 86_400_000

// ---------- GET /papi/puzzles/:id ----------

pub fn puzzle_json(ctx: Ctx, id: String) -> Result(String, ApiError) {
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  Ok(body(stored.id, question, tree_of(ctx, stored.id, question)))
}

/// The same answer with the tree worked out fresh, for a caller that has no
/// capabilities to read a cache with (the fixture task). What it renders is
/// byte for byte what a page receives, which is the point of a fixture.
pub fn puzzle_body(stored: caps.Stored) -> Result(String, ApiError) {
  use question <- result.try(question_of(stored))
  Ok(body(stored.id, question, fresh_tree(question)))
}

fn body(id: String, question: Question, tree: Json) -> String {
  envelope.ok([
    #("id", json.string(id)),
    #("kind", json.string(puzzles.kind_name(question.kind))),
    #("question", question_json(shown(question))),
    #("tree", tree),
    #("prompt", json.string(prompt(question))),
  ])
}

/// The sentence the page asks in and a link preview repeats. A checker play
/// names its roll; a cube question is two words, because the board and the
/// score already say everything else.
pub fn prompt(question: Question) -> String {
  case question.kind, question.dice {
    MoveKind, Some(#(high, low)) ->
      "White to play "
      <> int.to_string(high)
      <> "-"
      <> int.to_string(low)
      <> ". What's your play?"
    MoveKind, None -> "What's your play?"
    Double, _ -> "Double?"
    Take, _ -> "Take?"
  }
}

/// The question as the person being asked sees it, which is not always the
/// way it is stored. A `Take` is stored from the *doubler's* side -- the
/// same position as the `Double`, so the two are one board and one key --
/// but it is the responder who is being asked, and the page draws whoever
/// is being asked as White at the bottom. So a take is turned around: the
/// points reverse, the cube changes hands and the away scores swap.
pub fn shown(question: Question) -> Question {
  case question.kind {
    Take ->
      Question(
        ..question,
        board: puzzles.flip(question.board),
        cube_owner: case question.cube_owner {
          Mover -> Opponent
          Opponent -> Mover
          centered -> centered
        },
        away_mover: question.away_opponent,
        away_opponent: question.away_mover,
      )
    _ -> question
  }
}

fn question_json(q: Question) -> Json {
  json.object([
    #("board", position_json(q.board)),
    #("dice", case q.dice {
      Some(#(high, low)) -> json.array([high, low], json.int)
      None -> json.null()
    }),
    #(
      "cube",
      json.object([
        #("value", json.int(q.cube_value)),
        #("owner", json.string(puzzles.owner_name(q.cube_owner))),
      ]),
    ),
    #("score", case q.away_mover == 0 && q.away_opponent == 0 {
      True -> json.null()
      False ->
        json.object([
          #("mover_away", json.int(q.away_mover)),
          #("opponent_away", json.int(q.away_opponent)),
        ])
    }),
    #("crawford", json.bool(q.crawford)),
    #("jacoby", json.bool(q.jacoby)),
  ])
}

/// Every legal way to play the roll, or nothing at all for a cube question.
///
/// The tree is a pure function of the stored question, so it is worked out
/// once per puzzle and kept: the store is bounded and may forget, and a
/// miss only costs the build again.
fn tree_of(ctx: Ctx, id: String, question: Question) -> Json {
  case question.kind, question.dice {
    MoveKind, Some(roll) ->
      case ctx.puzzles.cached_tree(id) {
        Some(text) -> raw.json(text)
        None ->
          case tree.from_engine(question.board) {
            Error(_) -> json.null()
            Ok(b) -> {
              let text = json.to_string(tree.to_json(built(b, roll)))
              ctx.puzzles.keep_tree(id, text)
              raw.json(text)
            }
          }
      }
    _, _ -> json.null()
  }
}

fn fresh_tree(question: Question) -> Json {
  case question.kind, question.dice {
    MoveKind, Some(roll) ->
      case tree.from_engine(question.board) {
        Error(_) -> json.null()
        Ok(b) -> tree.to_json(built(b, roll))
      }
    _, _ -> json.null()
  }
}

/// The whole turn where it fits, the root alone where it does not.
fn built(b: Board, roll: #(Int, Int)) -> tree.Tree {
  let dice = tree.dice_of(roll)
  case tree.build(b, dice, tree_node_budget) {
    Error(_) -> tree.lazy_root(b, dice)
    Ok(whole) ->
      case
        string.byte_size(json.to_string(tree.to_json(whole)))
        <= tree_byte_budget
      {
        True -> whole
        False -> tree.lazy_root(b, dice)
      }
  }
}

// ---------- GET /papi/puzzles/:id/tree?node= ----------

/// One level of a tree served lazily. The node's own id carries the
/// position and the dice left, so this holds nothing between requests and
/// replays nothing: it applies the rules to a board the page is already
/// looking at. A node id that will not read back, or one whose dice are not
/// this puzzle's roll, is refused.
pub fn tree_node_json(
  ctx: Ctx,
  id: String,
  node: String,
) -> Result(String, ApiError) {
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  use roll <- result.try(
    question.dice
    |> option.to_result(error.NotFound(not_found_message)),
  )
  use parsed <- result.try(
    tree.from_lazy_id(node)
    |> result.replace_error(error.NotFound(not_found_message)),
  )
  let #(b, dice_left, moved) = parsed
  use _ <- result.try(case fits(dice_left, tree.dice_of(roll)) {
    True -> Ok(Nil)
    False -> Error(error.NotFound(not_found_message))
  })
  Ok(
    envelope.ok([
      #("node", json.string(node)),
      #("tree", tree.node_json(tree.level(b, dice_left, moved, node))),
    ]),
  )
}

/// Are these the dice a turn could still have left, out of that roll?
fn fits(left: List(Int), roll: List(Int)) -> Bool {
  case left {
    [] -> True
    [die, ..rest] -> list.contains(roll, die) && fits(rest, drop_one(roll, die))
  }
}

fn drop_one(dice: List(Int), die: Int) -> List(Int) {
  case dice {
    [] -> []
    [d, ..rest] if d == die -> rest
    [d, ..rest] -> [d, ..drop_one(rest, die)]
  }
}

// ---------- POST /papi/puzzles/:id/attempts ----------

/// What the client sent: a path through the tree, or a band on the cube
/// scale, and the key that makes a retry the same attempt.
pub type Attempted {
  Attempted(moves: List(#(String, String, Int)), band: Option(Int), key: String)
}

pub fn attempt_json(
  ctx: Ctx,
  session: Session,
  id: String,
  attempted: Attempted,
  now_ms: Int,
) -> Result(String, ApiError) {
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  use answer <- result.try(answer_of(stored))
  use judged <- result.try(judge(question, answer, attempted))
  let #(verdict, reveal, answer_row) = judged
  use scheduled <- result.try(schedule(
    ctx,
    session,
    stored.id,
    verdict,
    answer_row,
    attempted.key,
    now_ms,
  ))
  let #(verdict, schedule_json) = scheduled
  Ok(
    envelope.ok(
      list.flatten([
        [#("verdict", json.string(grade.verdict_name(verdict)))],
        reveal,
        [#("schedule", schedule_json)],
      ]),
    ),
  )
}

/// The verdict, the fields a reveal shows, and the answer as the row keeps
/// it. One place, so a cube question and a checker play cannot drift apart.
fn judge(
  question: Question,
  answer: Answer,
  attempted: Attempted,
) -> Result(#(Verdict, List(#(String, Json)), String), ApiError) {
  case question.kind {
    MoveKind -> judge_move(question, answer, attempted.moves)
    _ -> judge_cube(question, answer, attempted.band)
  }
}

fn judge_move(
  question: Question,
  answer: Answer,
  moves: List(#(String, String, Int)),
) -> Result(#(Verdict, List(#(String, Json)), String), ApiError) {
  let refused = error.validation_failed(bad_move_message)
  use start <- result.try(
    tree.from_engine(question.board) |> result.replace_error(refused),
  )
  use roll <- result.try(option.to_result(question.dice, refused))
  use played <- result.try(walk(start, tree.dice_of(roll), moves))
  // Half a turn is not an answer: PLAY is offered on a position where
  // nothing more can be played, and only there.
  use _ <- result.try(case tree.legal_children(played.0, played.1) {
    [] -> Ok(Nil)
    _ -> Error(refused)
  })
  let landed_on = analysis.encode(played.0, White)
  let cost = grade.move_cost(answer, landed_on)
  let verdict = grade.move_verdict(cost)
  let best = grade.best(answer)
  Ok(#(
    verdict,
    [
      #("yours", case yours(question, answer, landed_on, cost, best) {
        Some(c) -> c
        None -> json.null()
      }),
      #("best", case best {
        Some(c) -> candidate_json(question, c)
        None -> json.null()
      }),
      #("top", json.array(grade.top_five(answer), candidate_json(question, _))),
      #("cube", json.null()),
    ],
    json.to_string(
      json.object([
        #(
          "moves",
          json.array(played.2, fn(m) {
            json.object([
              #("from", json.string(board.loc_id(m.from))),
              #("to", json.string(board.loc_id(m.to))),
              #("die", json.int(m.die)),
            ])
          }),
        ),
      ]),
    ),
  ))
}

/// The play the player made, described as fully as the stored answer lets
/// us. A play the engine ranked comes back whole; one it only costed is
/// built from what we do have -- where it leaves the board, what it cost,
/// and where it stands among every legal play -- with no chances, because
/// there are none stored for it. A play the answer has never heard of is
/// nothing at all, which is what `unknown` means.
fn yours(
  question: Question,
  answer: Answer,
  landed_on: List(Int),
  cost: Option(Float),
  best: Option(Candidate),
) -> Option(Json) {
  case cost {
    None -> None
    Some(lost) ->
      case described(answer, landed_on) {
        Some(candidate) -> Some(candidate_json(question, candidate))
        None ->
          Some(
            json.object([
              #("rank", case grade.move_rank(answer, landed_on) {
                Some(rank) -> json.int(rank)
                None -> json.null()
              }),
              #("notation", json.string("")),
              #("equity", case best {
                Some(b) -> json.float(b.equity -. lost)
                None -> json.null()
              }),
              #("equity_lost", json.float(lost)),
              #("position", position_json(landed_on)),
              #("landed", landings_json(question, landed_on)),
              #("probs", json.null()),
            ]),
          )
      }
  }
}

fn described(answer: Answer, landed_on: List(Int)) -> Option(Candidate) {
  case answer {
    MoveAnswer(candidates: candidates, ..) ->
      list.find(candidates, fn(c) { c.board == landed_on })
      |> option.from_result
    CubeAnswer(..) -> None
  }
}

/// Walk a claimed path from the root: every step has to be one the rules
/// allow from where the last one left off, which is exactly what the page
/// was offered.
fn walk(
  b: Board,
  dice: List(Int),
  moves: List(#(String, String, Int)),
) -> Result(#(Board, List(Int), List(Move)), ApiError) {
  let refused = error.validation_failed(bad_move_message)
  case moves {
    [] -> Ok(#(b, dice, []))
    [#(from, to, die), ..rest] -> {
      use from <- result.try(
        board.parse_loc(from) |> result.replace_error(refused),
      )
      use to <- result.try(board.parse_loc(to) |> result.replace_error(refused))
      let wanted = Move(from: from, to: to, die: die)
      use _ <- result.try(
        case list.contains(tree.legal_children(b, dice), wanted) {
          True -> Ok(Nil)
          False -> Error(refused)
        },
      )
      let #(next, _, _) = board.apply_move(b, White, wanted)
      use walked <- result.try(walk(next, drop_one(dice, die), rest))
      let #(end, left, played) = walked
      Ok(#(end, left, [wanted, ..played]))
    }
  }
}

fn judge_cube(
  question: Question,
  answer: Answer,
  band: Option(Int),
) -> Result(#(Verdict, List(#(String, Json)), String), ApiError) {
  let refused = error.validation_failed(bad_band_message)
  use answered <- result.try(option.to_result(band, refused))
  use _ <- result.try(case grade.band_in_range(answered) {
    True -> Ok(Nil)
    False -> Error(refused)
  })
  use engine <- result.try(
    grade.engine_band(question.kind, answer)
    |> option.to_result(error.Internal(not_found_message)),
  )
  Ok(#(
    grade.cube_verdict(answered, engine),
    [
      #("yours", json.null()),
      #("best", json.null()),
      #("top", json.array([], fn(_) { json.null() })),
      #("cube", cube_json(answer, engine)),
    ],
    json.to_string(json.object([#("band", json.int(answered))])),
  ))
}

/// The engine's call, on the same scale the player answered on, over the
/// three equities it made it from. They are always the doubler's payoff,
/// whichever side was asked; the page says so in words.
fn cube_json(answer: Answer, engine: Int) -> Json {
  case answer {
    CubeAnswer(nd, dt, dp, probs, _optimal, too_good) ->
      json.object([
        #("band", json.int(engine)),
        #("no_double", json.float(nd)),
        #("double_take", json.float(dt)),
        #("double_pass", json.float(dp)),
        #("probs", case probs {
          Some(p) -> probs_json(p)
          None -> json.null()
        }),
        #("too_good", json.bool(too_good)),
      ])
    MoveAnswer(..) -> json.null()
  }
}

fn candidate_json(question: Question, c: Candidate) -> Json {
  json.object([
    #("rank", json.int(c.rank)),
    #("notation", json.string(c.notation)),
    #("equity", json.float(c.equity)),
    #("equity_lost", json.float(c.equity_lost)),
    #("position", position_json(c.board)),
    #("landed", landings_json(question, c.board)),
    #("probs", probs_json(c.probs)),
  ])
}

fn position_json(engine_board: List(Int)) -> Json {
  case tree.from_engine(engine_board) {
    Ok(b) -> tree.board_json(b)
    Error(_) -> json.null()
  }
}

/// Where the play's checkers landed, for a page that marks them without
/// reading notation. The mover is White on both boards, because a question
/// numbers its points from their side.
fn landings_json(question: Question, landed_on: List(Int)) -> Json {
  json.array(analysis.landings(question.board, landed_on, White), json.int)
}

fn probs_json(p: puzzles.Probs) -> Json {
  json.object([
    #("win", json.float(p.win)),
    #("gammon_win", json.float(p.gammon_win)),
    #("backgammon_win", json.float(p.backgammon_win)),
    #("gammon_loss", json.float(p.gammon_loss)),
    #("backgammon_loss", json.float(p.backgammon_loss)),
  ])
}

// ---------- The ladder ----------

/// What this answer did to the player's deck, and the verdict to report.
///
/// Nothing at all for a guest, or for a signed-in player whose deck does not
/// hold this puzzle: the answer is graded and revealed and forgotten, which
/// is exactly what a shared link is for.
///
/// For a player whose deck does hold it, the attempt is written first and
/// keyed by the client's own id. Only a row this call wrote may move the
/// ladder, and only while the card is due -- and a review always pushes the
/// due date out, so the second answer at the same opportunity finds nothing
/// to move. A retried key reports what its own attempt reported, and the
/// verdict it was given, so the page and the row never disagree.
fn schedule(
  ctx: Ctx,
  session: Session,
  id: String,
  verdict: Verdict,
  answer_row: String,
  key: String,
  now_ms: Int,
) -> Result(#(Verdict, Json), ApiError) {
  case session.user_id {
    None -> Ok(#(verdict, json.null()))
    Some(uid) -> {
      use _ <- result.try(case key {
        "" -> Error(error.validation_failed(no_key_message))
        _ -> Ok(Nil)
      })
      case ctx.practice.card(uid, id) {
        None -> Ok(#(verdict, json.null()))
        Some(card) -> {
          let attempt =
            ctx.puzzles.put_attempt(
              id,
              uid,
              key,
              answer_row,
              grade.verdict_name(verdict),
            )
          case attempt.fresh {
            False -> Ok(#(stored_verdict(attempt, verdict), kept(attempt)))
            True -> move_ladder(ctx, uid, id, card, verdict, attempt, now_ms)
          }
        }
      }
    }
  }
}

/// The verdict the row already holds. A key is one answer: if a client
/// reuses it for a different one, the row is what stands.
fn stored_verdict(attempt: caps.Attempt, fresh: Verdict) -> Verdict {
  case attempt.verdict {
    "pass" -> Pass
    "hold" -> Hold
    "fail" -> Fail
    "unknown" -> Unknown
    _ -> fresh
  }
}

fn kept(attempt: caps.Attempt) -> Json {
  case attempt.schedule_json {
    "" -> json.null()
    text -> raw.json(text)
  }
}

fn move_ladder(
  ctx: Ctx,
  uid: String,
  id: String,
  card: Card,
  verdict: Verdict,
  attempt: caps.Attempt,
  now_ms: Int,
) -> Result(#(Verdict, Json), ApiError) {
  // A card nobody has seen yet is introduced by being answered: that is
  // what "new" means from the player's side.
  let card = case card.status {
    New -> {
      let _ = ctx.practice.start(uid, [id])
      practice.Card(..card, status: Active, due_ms: now_ms)
    }
    _ -> card
  }
  case card.status, card.due_ms <= now_ms, verdict {
    // Put aside: it is out of the rotation, so there is nothing to move and
    // nothing to say about when it comes back.
    Suspended, _, _ -> {
      settle(ctx, attempt, False, None, "")
      Ok(#(verdict, json.null()))
    }
    // Answered again before it is due: the reveal, and nothing else.
    _, False, _ -> {
      let body =
        schedule_json(card.level, card.level, card.due_ms, False, False)
      settle(ctx, attempt, False, None, body)
      Ok(#(verdict, raw.json(body)))
    }
    // The engine has no result for this play, so nobody may be told they
    // were wrong. The card waits until tomorrow rather than sitting due in
    // front of new material, and the player grades themselves.
    _, True, Unknown -> {
      let due = now_ms + day_ms
      let level = case deck.snooze(ctx, uid, id, due) {
        Ok(graded) -> graded.level_after
        Error(_) -> card.level
      }
      let body = schedule_json(card.level, level, due, False, True)
      settle(ctx, attempt, False, None, body)
      Ok(#(verdict, raw.json(body)))
    }
    _, True, _ ->
      case deck.answer(ctx, uid, id, outcome_of(verdict)) {
        Error(refusal) -> Error(refusal)
        Ok(graded) -> {
          let body =
            schedule_json(
              graded.level_before,
              graded.level_after,
              graded.due_ms,
              True,
              False,
            )
          settle(ctx, attempt, True, Some(graded.review_id), body)
          Ok(#(verdict, raw.json(body)))
        }
      }
  }
}

/// How the deck reads a verdict. A miss goes back to the start rather than
/// down a rung: the brief promises a puzzle you got wrong tomorrow, whatever
/// level it had.
fn outcome_of(verdict: Verdict) -> Outcome {
  case verdict {
    Pass -> PassOutcome
    Hold -> Partial
    _ -> Again
  }
}

fn settle(
  ctx: Ctx,
  attempt: caps.Attempt,
  scheduled: Bool,
  review_id: Option(Int),
  body: String,
) -> Nil {
  ctx.puzzles.settle_attempt(attempt.id, scheduled, review_id, None, body)
}

fn schedule_json(
  before: Int,
  after: Int,
  due_ms: Int,
  amendable: Bool,
  self_grade: Bool,
) -> String {
  json.to_string(
    json.object([
      #("level_before", json.int(before)),
      #("level_after", json.int(after)),
      // Unix milliseconds, as every time on this wire is.
      #("due", json.int(due_ms)),
      #("amendable", json.bool(amendable)),
      #("self_grade", json.bool(self_grade)),
    ]),
  )
}

// ---------- POST /papi/puzzles/:id/attempts/:key/outcome ----------

/// The player's own word on how it went, after the reveal: the four buttons.
///
/// It **replaces** the automatic review rather than stacking on it -- a pass
/// then SOONER lands at level 0 once, not below -- because the deck's log is
/// append-only and a correction supersedes the row it names. Where there was
/// no automatic review (the engine could not grade the play), this writes the
/// first one. NEVER is a deck action: it puts the card aside, and works on
/// any card the deck holds.
pub fn outcome_json(
  ctx: Ctx,
  session: Session,
  id: String,
  key: String,
  outcome: String,
) -> Result(String, ApiError) {
  use wanted <- result.try(
    named(outcome)
    |> result.replace_error(error.validation_failed(
      "That is not one of the four answers",
    )),
  )
  use uid <- result.try(
    session.user_id |> option.to_result(error.Forbidden(not_yours_message)),
  )
  use attempt <- result.try(
    ctx.puzzles.attempt(id, key)
    |> option.to_result(error.NotFound(not_found_message)),
  )
  use _ <- result.try(case attempt.user_id == uid {
    True -> Ok(Nil)
    False -> Error(error.Forbidden(not_yours_message))
  })
  // Every override is a deck action, and there is no deck action on a card
  // the deck does not hold.
  use _ <- result.try(
    ctx.practice.card(uid, id)
    |> option.to_result(error.Conflict(nothing_to_amend_message)),
  )
  case wanted {
    Never -> {
      let _ = ctx.practice.suspend(uid, [id])
      ctx.puzzles.settle_attempt(
        attempt.id,
        attempt.scheduled,
        attempt.review_id,
        Some(outcome),
        "",
      )
      Ok(envelope.ok([#("schedule", json.null())]))
    }
    _ -> {
      let chosen = chosen_outcome(wanted, attempt.verdict)
      use graded <- result.try(case attempt.review_id {
        // Correct the review this attempt wrote. The attempt keeps naming
        // that same row, so a second thought replaces the first rather than
        // correcting the correction.
        Some(review_id) -> deck.correct(ctx, uid, id, review_id, chosen)
        // Nothing to correct: either the engine could not grade the play and
        // the player is grading it themselves, or there was never anything
        // at stake here.
        None ->
          case attempt.verdict == grade.verdict_name(Unknown) {
            True -> deck.answer(ctx, uid, id, chosen)
            False -> Error(error.Conflict(nothing_to_amend_message))
          }
      })
      let body =
        schedule_json(
          graded.level_before,
          graded.level_after,
          graded.due_ms,
          True,
          False,
        )
      ctx.puzzles.settle_attempt(
        attempt.id,
        True,
        Some(option.unwrap(attempt.review_id, graded.review_id)),
        Some(outcome),
        body,
      )
      Ok(envelope.ok([#("schedule", raw.json(body))]))
    }
  }
}

type Override {
  Sooner
  GotIt
  KnewIt
  Never
}

fn named(outcome: String) -> Result(Override, Nil) {
  case outcome {
    "sooner" -> Ok(Sooner)
    "got_it" -> Ok(GotIt)
    "knew_it" -> Ok(KnewIt)
    "never" -> Ok(Never)
    _ -> Error(Nil)
  }
}

/// GOT IT means "as graded": the engine's own verdict, or -- where it had
/// none -- a plain pass, which is what the player is claiming.
fn chosen_outcome(wanted: Override, verdict: String) -> Outcome {
  case wanted {
    Sooner -> Again
    KnewIt -> Known
    Never -> Again
    GotIt ->
      case verdict {
        "pass" -> PassOutcome
        "hold" -> Partial
        "fail" -> Again
        _ -> PassOutcome
      }
  }
}

// ---------- GET /papi/puzzles/:id/mine ----------

/// The line only the two people who played the game ever see: whose mistake
/// this was, what they played, what it cost, and the moment in the replay it
/// came from.
///
/// Held by the one holder rule, either seat: the person who made the mistake
/// and the person it was made against are both in this game, and both are
/// shown it. Anybody else gets the same 404 a puzzle nobody played gets.
pub fn mine_json(
  ctx: Ctx,
  session: Session,
  id: String,
) -> Result(String, ApiError) {
  let nothing = error.NotFound(no_memory_message)
  // A visitor with neither a guest cookie nor an account holds no seat
  // anywhere, and asking the rows would only prove it.
  use _ <- result.try(case session.guest_id, session.user_id {
    None, None -> Error(nothing)
    _, _ -> Ok(Nil)
  })
  use found <- result.try(
    ctx.puzzles.mine(
      id,
      option.unwrap(session.guest_id, ""),
      option.unwrap(session.user_id, ""),
    )
    |> list.filter_map(fn(room) {
      case seat.held_by(seats_of(room), session) {
        Some(player_id) -> Ok(#(room, player_id))
        None -> Error(Nil)
      }
    })
    |> list.first
    |> result.replace_error(nothing),
  )
  let #(room, player_id) = found
  let source = room.source
  let mine = source.player_id == player_id
  Ok(
    envelope.ok([
      #(
        "who",
        json.string(case mine {
          True -> "you"
          False -> name_of(room, source.player_id)
        }),
      ),
      #("played", json.string(source.played)),
      #("equity_lost", json.float(source.equity_lost)),
      #("grade", json.string(source.grade)),
      #("date", json.string(source.date)),
      #("result", result_json(ctx, room, player_id)),
      #("replay", json.string(replay_link(ctx, room))),
    ]),
  )
}

fn seats_of(room: caps.SourceRoom) -> List(seat.Seat) {
  list.map(room.seats, fn(s) {
    seat.Seat(
      player_id: s.0,
      guest_id: unless_empty(s.2),
      user_id: unless_empty(s.3),
    )
  })
}

fn unless_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

fn name_of(room: caps.SourceRoom, player_id: String) -> String {
  list.find(room.seats, fn(s) { s.0 == player_id })
  |> result.map(fn(s) { s.1 })
  |> result.unwrap("")
}

/// How that game ended, from the reader's own side. Read off the record row
/// the game wrote when it finished; a game with no row yet simply has no
/// result to report.
fn result_json(ctx: Ctx, room: caps.SourceRoom, player_id: String) -> Json {
  let source = room.source
  case
    ctx.records.stored(source.game_id)
    |> list.find(fn(row) { row.game_number == source.game_number })
  {
    Error(_) -> json.null()
    Ok(row) ->
      case json.parse(row.entries_json, game_over_decoder()) {
        Ok(Some(#(winner, points))) ->
          json.object([
            #("won", json.bool(winner == player_id)),
            #("points", json.int(points)),
          ])
        _ -> json.null()
      }
  }
}

/// The winner and the points of the one `game_over` line a game's record
/// ends on. Everything else in the record is a turn, and none of it is this
/// line's business.
fn game_over_decoder() -> decode.Decoder(Option(#(String, Int))) {
  use entries <- decode.then(decode.list(record_entry_decoder()))
  decode.success(
    entries
    |> list.filter_map(option.to_result(_, Nil))
    |> list.first
    |> option.from_result,
  )
}

fn record_entry_decoder() -> decode.Decoder(Option(#(String, Int))) {
  use kind <- decode.optional_field("kind", "", decode.string)
  case kind {
    "game_over" -> {
      use winner <- decode.optional_field("winner", "", decode.string)
      use points <- decode.optional_field("points", 0, decode.int)
      decode.success(Some(#(winner, points)))
    }
    _ -> decode.success(None)
  }
}

/// Where in the replay this decision was made. The review already knows
/// which line of the record each of its turns is (`entry`, `double_entry`,
/// `answer_entry`), and a step is that line plus one, because step zero is
/// the position the game opened from.
fn replay_link(ctx: Ctx, room: caps.SourceRoom) -> String {
  let source = room.source
  let base =
    "/"
    <> room.slug
    <> "/"
    <> source.game_id
    <> "/replay?game="
    <> int.to_string(source.game_number)
  case step_of(ctx, source) {
    Some(step) -> base <> "&step=" <> int.to_string(step)
    None -> base
  }
}

fn step_of(ctx: Ctx, source: caps.Source) -> Option(Int) {
  let field = case source.kind {
    "double" -> "double_entry"
    "take" -> "answer_entry"
    _ -> "entry"
  }
  case ctx.analysis.report(source.game_id, source.game_number) {
    None -> None
    Some(text) ->
      case json.parse(text, entries_decoder(field)) {
        Error(_) -> None
        Ok(entries) ->
          case list.drop(entries, source.turn - 1) |> list.first {
            Ok(Some(entry)) -> Some(entry + 1)
            _ -> None
          }
      }
  }
}

fn entries_decoder(field: String) -> decode.Decoder(List(Option(Int))) {
  decode.at(["turns"], decode.list(entry_decoder(field)))
}

fn entry_decoder(field: String) -> decode.Decoder(Option(Int)) {
  use value <- decode.optional_field(field, None, decode.optional(decode.int))
  decode.success(value)
}

// ---------- GET /papi/games/:slug/rooms/:id/puzzles?game=n ----------

/// The mistakes one game of a room made, for the seat the caller holds.
///
/// Theirs only: the card at game over offers "practise this game's six
/// mistakes", and they are the six the reader made, not their opponent's. A
/// caller at no seat here is the same 404 as a game that is not there, so
/// nobody reads a room they are not sitting at.
pub fn game_puzzles_json(
  ctx: Ctx,
  session: Session,
  slug: String,
  game_id: String,
  number: Int,
) -> Result(String, ApiError) {
  let nothing = error.NotFound(no_game_message)
  use setup <- result.try(case ctx.records.setup(game_id) {
    Some(setup) if setup.slug == slug -> Ok(setup)
    _ -> Error(nothing)
  })
  use player_id <- result.try(
    seat.held_by(
      list.map(setup.seats, fn(s) {
        seat.Seat(
          player_id: s.0,
          guest_id: unless_empty(s.2),
          user_id: unless_empty(s.3),
        )
      }),
      session,
    )
    |> option.to_result(nothing),
  )
  use _ <- result.try(case list.contains(ctx.records.numbers(game_id), number) {
    True -> Ok(Nil)
    False -> Error(nothing)
  })
  Ok(
    envelope.ok([
      #(
        "puzzles",
        json.array(
          ctx.puzzles.game_sources(game_id, number)
            |> list.filter(fn(s) {
              s.player_id == player_id && s.puzzle_id != ""
            }),
          fn(source) {
            json.object([
              #("id", json.string(source.puzzle_id)),
              #("kind", json.string(source.kind)),
              #("prompt", json.string(prompt_of(source))),
              // Whether it is due is the deck's to say, and the deck is
              // asked at /papi/practice. A game's own list is every mistake
              // of that game, in order, whatever the ladder thinks.
              #("due", json.bool(False)),
            ])
          },
        ),
      ),
      #("cursor", json.null()),
      #("counts", json.null()),
      #("game", json.int(number)),
    ]),
  )
}

fn prompt_of(source: caps.Source) -> String {
  case puzzles.question_from_json(source.question_json) {
    Ok(question) -> prompt(question)
    Error(_) ->
      case source.kind {
        "double" -> "Double?"
        "take" -> "Take?"
        _ -> "What's your play?"
      }
  }
}

// ---------- Reading a puzzle back ----------

fn fetch(ctx: Ctx, id: String) -> Result(caps.Stored, ApiError) {
  ctx.puzzles.get(id)
  |> option.to_result(error.NotFound(not_found_message))
}

fn question_of(stored: caps.Stored) -> Result(Question, ApiError) {
  puzzles.question_from_json(stored.question_json)
  |> result.replace_error(error.Internal(not_found_message))
}

fn answer_of(stored: caps.Stored) -> Result(Answer, ApiError) {
  puzzles.answer_from_json(stored.answer_json)
  |> result.replace_error(error.Internal(not_found_message))
}
