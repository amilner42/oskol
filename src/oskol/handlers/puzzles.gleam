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
import backgammon/board.{type Board, White}
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
import oskol/handlers/shares
import oskol/practice/deck
import oskol/puzzles.{
  type Answer, type Candidate, type Question, CubeAnswer, Move as MoveKind,
  MoveAnswer, Mover, Opponent, Question, Take,
}
import oskol/puzzles/game_over
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

/// The absolute ceiling on working a turn out at all, for the few positions
/// that will not fit on the wire and are played a level at a time. Far above
/// anything real -- the worst position in four thousand from actual play
/// needed 539, and the most contrived doubles anyone could build need about
/// 2,400 -- so it is not a budget but a guard: a position past it is one
/// nobody has ever reached, and no request is spent on it.
pub const tree_ceiling = 20_000

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

// ---------- The head of /puzzles/:id ----------

/// What the server writes into the document head of a puzzle's page,
/// before the client has fetched anything: the question as its title
/// (what a link unfurls as) and the score and cube as its description.
/// Nothing else -- no name, no source game, no answer -- because the head
/// is read by every crawler and every chat app a link is pasted into.
///
/// The one exception is the sharer's own name, on a link they minted to
/// carry it (`?s=`, `handlers/shares`): "Arie got this wrong. What's your
/// play?" as the title, the description as it always is. A token that
/// opens no story here leaves the head exactly as it was.
pub type Head {
  Head(title: String, description: String)
}

pub fn head(ctx: Ctx, id: String, share: String) -> Result(Head, ApiError) {
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  let q = shown(question)
  let title = case shares.sharer(ctx, stored.id, share) {
    Some(name) -> shares.headline(name, q)
    None -> prompt(q)
  }
  Ok(Head(title: title, description: describe(q)))
}

/// The score and the cube in a sentence: "Match play, 3 away against 5.
/// Cube at 2, White's." The same words the board's picture captions
/// (`oskol/puzzles/picture`): no score is unlimited play, and one point
/// each way is a single game -- a 1-point match and a single game are the
/// same position, unless it is marked Crawford, which only a match is.
pub fn describe(q: Question) -> String {
  let score = case q.away_mover, q.away_opponent, q.crawford {
    0, 0, _ -> "Unlimited play"
    1, 1, False -> "Single game"
    mine, theirs, crawford ->
      "Match play, "
      <> int.to_string(mine)
      <> " away against "
      <> int.to_string(theirs)
      <> case crawford {
        True -> ", Crawford"
        False -> ""
      }
  }
  let cube = case q.cube_owner {
    Mover -> "Cube at " <> int.to_string(q.cube_value) <> ", White's."
    Opponent -> "Cube at " <> int.to_string(q.cube_value) <> ", Black's."
    _ -> "Cube centred."
  }
  score <> ". " <> cube <> " A backgammon puzzle: play it on the board."
}

/// The sentence the page asks in, the head and the picture repeat, and a
/// session lists a puzzle by: `oskol/puzzles.prompt`, the one sentence,
/// asked from the solver's side.
pub fn prompt(question: Question) -> String {
  puzzles.prompt(question)
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
/// The payload is a pure function of the stored question, so it is worked
/// out once per puzzle and kept: the store is bounded and may forget, and a
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
              let text = json.to_string(tree.to_json(payload(ctx, id, b, roll)))
              ctx.puzzles.keep_tree(id, text)
              raw.json(text)
            }
          }
      }
    _, _ -> json.null()
  }
}

/// The whole turn where it fits on the wire, the root alone where it does
/// not.
///
/// A turn that does not fit is worked out in full anyway, once, and kept.
/// The page then walks it by the ids that build gave them, one level per
/// request, and every one of those is a lookup rather than a search: the
/// difference between paying for the position once and paying for it on
/// every tap. It is also what makes a node id mean something, because an
/// id nobody minted for this puzzle is simply not in it.
fn payload(ctx: Ctx, id: String, b: Board, roll: #(Int, Int)) -> tree.Tree {
  let dice = tree.dice_of(roll)
  case within_budget(b, dice) {
    Some(whole) -> whole
    None ->
      case full_tree(ctx, id, b, dice) {
        Some(whole) -> tree.lazy_view(whole)
        // Past even the ceiling: no position anybody has reached, and not
        // worth a request. The page draws the question with nothing to tap.
        None -> tree.Tree(root: tree.root_id, nodes: [], lazy: True)
      }
  }
}

/// The whole turn, if it is small enough to send whole.
fn within_budget(b: Board, dice: List(Int)) -> Option(tree.Tree) {
  case tree.build(b, dice, tree_node_budget) {
    Error(_) -> None
    Ok(whole) ->
      case
        string.byte_size(json.to_string(tree.to_json(whole)))
        <= tree_byte_budget
      {
        True -> Some(whole)
        False -> None
      }
  }
}

/// This puzzle's turn worked out in full, from the store or built once and
/// kept there. Only ever reached for a turn too big to send whole, which is
/// the only kind worth keeping: one that fits is a few dozen positions and
/// is cheaper to rebuild than to store.
fn full_tree(
  ctx: Ctx,
  id: String,
  b: Board,
  dice: List(Int),
) -> Option(tree.Tree) {
  case ctx.puzzles.cached_moves(id) {
    Some(whole) -> Some(whole)
    None ->
      case tree.build(b, dice, tree_ceiling) {
        Error(_) -> None
        Ok(whole) -> {
          ctx.puzzles.keep_moves(id, whole)
          Some(whole)
        }
      }
  }
}

/// The turn a question asks about, worked out in full: what an attempt is
/// checked against and what a level request reads.
fn moves_of(ctx: Ctx, id: String, question: Question) -> Option(tree.Tree) {
  case question.dice {
    None -> None
    Some(roll) ->
      case tree.from_engine(question.board) {
        Error(_) -> None
        Ok(b) -> {
          let dice = tree.dice_of(roll)
          case within_budget(b, dice) {
            Some(whole) -> Some(whole)
            None -> full_tree(ctx, id, b, dice)
          }
        }
      }
  }
}

/// The same payload with nothing kept, for a caller with no capabilities to
/// keep it with (the fixture task). A position too big to send whole has no
/// fixture: there is nothing for a page to decode in one.
fn fresh_tree(question: Question) -> Json {
  case question.kind, fresh_moves(question) {
    MoveKind, Some(whole) -> tree.to_json(whole)
    _, _ -> json.null()
  }
}

/// The turn worked out and kept nowhere, where it fits on the wire.
fn fresh_moves(question: Question) -> Option(tree.Tree) {
  case question.dice {
    None -> None
    Some(roll) ->
      case tree.from_engine(question.board) {
        Error(_) -> None
        Ok(b) -> within_budget(b, tree.dice_of(roll))
      }
  }
}

// ---------- GET /papi/puzzles/:id/tree?node= ----------

/// One level of a tree served lazily.
///
/// The node is named by the id this puzzle's own build gave it, so there is
/// nothing to validate and nothing to forge: an id this puzzle does not
/// hold is a 404, and no board a caller made up is ever played out. The
/// tree is read from the store, so a level costs a lookup.
pub fn tree_node_json(
  ctx: Ctx,
  id: String,
  node: String,
) -> Result(String, ApiError) {
  let nothing = error.NotFound(not_found_message)
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  use whole <- result.try(
    moves_of(ctx, stored.id, question) |> option.to_result(nothing),
  )
  use found <- result.try(
    tree.node_by_id(whole, node) |> option.to_result(nothing),
  )
  Ok(
    envelope.ok([
      #("node", json.string(node)),
      #("tree", tree.node_json(found)),
    ]),
  )
}

// ---------- POST /papi/puzzles/:id/attempts ----------

/// What the client sent: a path through the tree, or a band on the cube
/// scale, and the key that makes a retry the same attempt.
pub type Attempted {
  Attempted(moves: List(#(String, String, Int)), band: Option(Int), key: String)
}

/// `share` is the `?s=` the page was opened with, or "": the story it
/// opens rides on the reveal and nowhere earlier, because it says what was
/// played and how that was graded (`handlers/shares`).
pub fn attempt_json(
  ctx: Ctx,
  session: Session,
  id: String,
  attempted: Attempted,
  share: String,
  now_ms: Int,
) -> Result(String, ApiError) {
  use stored <- result.try(fetch(ctx, id))
  use question <- result.try(question_of(stored))
  use answer <- result.try(answer_of(stored))
  use judged <- result.try(judge(
    fn() { moves_of(ctx, stored.id, question) },
    question,
    answer,
    attempted,
  ))
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
  Ok(reveal_body(
    verdict,
    reveal,
    schedule_json,
    shares.story_json(ctx, stored.id, shown(question), share),
  ))
}

/// The same reveal with nothing kept and nobody signed in -- what a guest
/// on a shared link is shown, byte for byte -- for a caller with no
/// capabilities (the fixture task). A turn too big to send whole has no
/// fixture, as `puzzle_body` has none.
pub fn attempt_body(
  stored: caps.Stored,
  attempted: Attempted,
) -> Result(String, ApiError) {
  use question <- result.try(question_of(stored))
  use answer <- result.try(answer_of(stored))
  use judged <- result.try(judge(
    fn() { fresh_moves(question) },
    question,
    answer,
    attempted,
  ))
  let #(verdict, reveal, _row) = judged
  Ok(reveal_body(verdict, reveal, json.null(), json.null()))
}

fn reveal_body(
  verdict: Verdict,
  reveal: List(#(String, Json)),
  schedule_json: Json,
  story_json: Json,
) -> String {
  envelope.ok(
    list.flatten([
      [#("verdict", json.string(grade.verdict_name(verdict)))],
      reveal,
      [#("schedule", schedule_json), #("story", story_json)],
    ]),
  )
}

/// The verdict, the fields a reveal shows, and the answer as the row keeps
/// it. One place, so a cube question and a checker play cannot drift apart.
/// The turn is asked for only where a checker play needs it.
fn judge(
  moves: fn() -> Option(tree.Tree),
  question: Question,
  answer: Answer,
  attempted: Attempted,
) -> Result(#(Verdict, List(#(String, Json)), String), ApiError) {
  case question.kind {
    MoveKind -> {
      use whole <- result.try(
        moves()
        |> option.to_result(error.validation_failed(bad_move_message)),
      )
      judge_move(whole, question, answer, attempted.moves)
    }
    _ -> judge_cube(question, answer, attempted.band)
  }
}

fn judge_move(
  whole: tree.Tree,
  question: Question,
  answer: Answer,
  moves: List(#(String, String, Int)),
) -> Result(#(Verdict, List(#(String, Json)), String), ApiError) {
  let refused = error.validation_failed(bad_move_message)
  // Walked through the turn that was actually offered, rather than worked
  // out again a step at a time: the same positions, and no search per move.
  use played <- result.try(walk(whole, tree.root_id, moves, []))
  let #(ended, steps) = played
  // Half a turn is not an answer: PLAY is offered on a position where
  // nothing more can be played, and only there.
  use _ <- result.try(case ended.children {
    [] -> Ok(Nil)
    _ -> Error(refused)
  })
  let landed_on = analysis.encode(ended.board, White)
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
          json.array(steps, fn(m) {
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

/// Walk a claimed path from the root of the turn the page was given. Every
/// step has to be a child of where the last one left off, which is exactly
/// what the page was offered -- so an attempt is checked against the same
/// tree it was played on, not against a fresh opinion about the rules.
fn walk(
  whole: tree.Tree,
  from: String,
  moves: List(#(String, String, Int)),
  so_far: List(tree.Child),
) -> Result(#(tree.Node, List(tree.Child)), ApiError) {
  let refused = error.validation_failed(bad_move_message)
  use here <- result.try(
    tree.node_by_id(whole, from) |> option.to_result(refused),
  )
  case moves {
    [] -> Ok(#(here, list.reverse(so_far)))
    [#(from_loc, to_loc, die), ..rest] -> {
      use step <- result.try(
        list.find(here.children, fn(c) {
          board.loc_id(c.from) == from_loc
          && board.loc_id(c.to) == to_loc
          && c.die == die
        })
        |> result.replace_error(refused),
      )
      walk(whole, step.node, rest, [step, ..so_far])
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
      // Everything from here to the card moving is one account, one puzzle,
      // one at a time: whether this answer counts is read-then-act, and two
      // tabs that both read a due card would otherwise both move it.
      use scheduled <- result.try(
        ctx.puzzles.serialize(uid, id, fn() {
          decide(ctx, uid, id, verdict, answer_row, key, now_ms)
        }),
      )
      Ok(
        #(
          named_verdict(scheduled.verdict, verdict),
          case scheduled.schedule_json {
            "" -> json.null()
            text -> raw.json(text)
          },
        ),
      )
    }
  }
}

/// What this answer does, decided with nobody else deciding it. Nothing for
/// a puzzle the caller's deck does not hold: the answer is graded and
/// revealed and forgotten, which is exactly what a shared link is for.
fn decide(
  ctx: Ctx,
  uid: String,
  id: String,
  verdict: Verdict,
  answer_row: String,
  key: String,
  now_ms: Int,
) -> Result(caps.Scheduled, ApiError) {
  case card_of(ctx, uid, id) {
    None -> Ok(caps.Scheduled(grade.verdict_name(verdict), ""))
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
        // The key was already there: this is the same answer arriving
        // twice, and it reports what it reported the first time.
        False -> Ok(caps.Scheduled(attempt.verdict, attempt.schedule_json))
        True -> move_ladder(ctx, uid, id, card, verdict, attempt, now_ms)
      }
    }
  }
}

/// A verdict by name, falling back to the one just worked out. A key is one
/// answer: where a client reuses it for a different one, the row stands.
fn named_verdict(name: String, fallback: Verdict) -> Verdict {
  case name {
    "pass" -> Pass
    "hold" -> Hold
    "fail" -> Fail
    "unknown" -> Unknown
    _ -> fallback
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
) -> Result(caps.Scheduled, ApiError) {
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
      Ok(caps.Scheduled(grade.verdict_name(verdict), ""))
    }
    // Answered again before it is due: the reveal, and nothing else.
    _, False, _ -> {
      let body =
        schedule_json(card.level, card.level, card.due_ms, False, False)
      settle(ctx, attempt, False, None, body)
      Ok(caps.Scheduled(grade.verdict_name(verdict), body))
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
      Ok(caps.Scheduled(grade.verdict_name(verdict), body))
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
          Ok(caps.Scheduled(grade.verdict_name(verdict), body))
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

/// The schedule as the wire carries it. Public so the fixture task can hand
/// the client's tests every shape a page has to draw.
pub fn schedule_json(
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
/// append-only and a correction supersedes the row it names. Where the
/// engine could not grade the play there is no review to correct, and this
/// writes the first one instead -- but only where the answer actually
/// offered that (`self_grade`), never merely because no review was written.
/// NEVER is a deck action: it puts the card aside without touching the
/// attempt's own schedule, and nothing can be overridden afterwards.
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
  // By account, never by key alone: a key is a uuid the client made up and
  // is only unique within one deck.
  use attempt <- result.try(
    ctx.puzzles.attempt(id, uid, key)
    |> option.to_result(error.NotFound(not_found_message)),
  )
  // Every override is a deck action, and there is no deck action on a card
  // the deck does not hold.
  use _ <- result.try(
    card_of(ctx, uid, id) |> option.to_result(nothing_to_amend()),
  )
  // Once a card has been put aside there is nothing left to say about it.
  // Pressing NEVER again is the same action and answers the same way.
  use _ <- result.try(case attempt.outcome == Some(never_name), wanted {
    True, Never -> Ok(Nil)
    True, _ -> Error(nothing_to_amend())
    False, _ -> Ok(Nil)
  })
  case wanted {
    Never -> {
      let _ = ctx.practice.suspend(uid, [id])
      // The attempt's own schedule stands: suspending is something done to
      // the card, and a retry of the answer that wrote it must still come
      // back with what it came back with.
      ctx.puzzles.settle_attempt(
        attempt.id,
        attempt.scheduled,
        attempt.review_id,
        Some(outcome),
        "",
      )
      Ok(envelope.ok([#("schedule", kept(attempt))]))
    }
    _ -> {
      let chosen = chosen_outcome(wanted, attempt.verdict)
      use graded <- result.try(case attempt.review_id {
        // Correct the review this attempt wrote. The attempt keeps naming
        // that same row, so a second thought replaces the first rather than
        // correcting the correction.
        Some(review_id) -> deck.correct(ctx, uid, id, review_id, chosen)
        // No review to correct. That is only an invitation to write one
        // where the answer said so -- the engine could not grade the play
        // and asked the player to. Anywhere else (a card that was not due,
        // one already put aside) there was no opportunity here, and writing
        // a review would be inventing one.
        None ->
          case self_graded(attempt) {
            True -> deck.answer(ctx, uid, id, chosen)
            False -> Error(nothing_to_amend())
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

/// Where one puzzle stands in this account's deck, if the deck holds it at
/// all. The deck answers about a list of keys, because a session asks about
/// a session's worth; an attempt is about one.
fn card_of(ctx: Ctx, uid: String, id: String) -> Option(Card) {
  ctx.practice.cards(uid, [id]) |> list.first |> option.from_result
}

fn nothing_to_amend() -> ApiError {
  error.Conflict("nothing_to_amend", nothing_to_amend_message)
}

/// Did this answer ask the player to grade it themselves? The schedule the
/// attempt reported is what said so, and it is on the row, so the question
/// is answered from the row rather than guessed from the verdict.
fn self_graded(attempt: caps.Attempt) -> Bool {
  case attempt.schedule_json {
    "" -> False
    text ->
      json.parse(text, {
        use flag <- decode.optional_field("self_grade", False, decode.bool)
        decode.success(flag)
      })
      |> result.unwrap(False)
  }
}

type Override {
  Sooner
  GotIt
  KnewIt
  Never
}

const never_name = "never"

fn named(outcome: String) -> Result(Override, Nil) {
  case outcome {
    "sooner" -> Ok(Sooner)
    "got_it" -> Ok(GotIt)
    "knew_it" -> Ok(KnewIt)
    "never" -> Ok(Never)
    _ -> Error(Nil)
  }
}

/// GOT IT means "as graded". Where the engine graded the play, that is its
/// own verdict. Where it could not, the player is claiming they got it --
/// which holds the card's level rather than moving it up, because nothing
/// checked the claim.
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
        _ -> Partial
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
      // The other seat, by its display name, so the line can say whose
      // game it was: "From your game vs Charlie". The reader's own name is
      // never sent back to them.
      #("opponent", json.string(opponent_of(room, player_id))),
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

fn opponent_of(room: caps.SourceRoom, player_id: String) -> String {
  list.find(room.seats, fn(s) { s.0 != player_id })
  |> result.map(fn(s) { s.1 })
  |> result.unwrap("")
}

fn name_of(room: caps.SourceRoom, player_id: String) -> String {
  list.find(room.seats, fn(s) { s.0 == player_id })
  |> result.map(fn(s) { s.1 })
  |> result.unwrap("")
}

/// How that game ended, from the reader's own side. One row, read by game
/// number: a match's other games have nothing to say about this one, and a
/// whole match's lines is a lot to fetch to learn who won a single game.
fn result_json(ctx: Ctx, room: caps.SourceRoom, player_id: String) -> Json {
  let source = room.source
  case ctx.records.entries_of(source.game_id, source.game_number) {
    None -> json.null()
    Some(entries) ->
      case game_over.of(entries) {
        Some(#(winner, points)) ->
          json.object([
            #("won", json.bool(winner == player_id)),
            #("points", json.int(points)),
          ])
        None -> json.null()
      }
  }
}

/// Where in the replay this decision was made. The review already knows
/// which line of the record each of its turns is, and a step is that line
/// plus one, because step zero is the position the game opened from.
///
/// Only that one turn is read: the review itself is hundreds of kilobytes
/// and the database takes the path.
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
  case
    ctx.analysis.report_turn(source.game_id, source.game_number, source.turn)
  {
    None -> None
    Some(text) ->
      case json.parse(text, lines_decoder()) {
        Error(_) -> None
        Ok(lines) -> option.map(line_of(source.kind, lines), fn(n) { n + 1 })
      }
  }
}

/// Which line of the record a decision sits on.
///
/// A double has a line of its own. A *missed* double does not -- nothing
/// was offered, so the mistake is marked on the move that was played
/// instead, and the replay reads it off `entry`. The take of a double is
/// always answered, so it always has its own line and never falls back.
/// The same rule the replay's own mistake list follows (`Page/Replay.elm`).
fn line_of(kind: String, lines: Lines) -> Option(Int) {
  case kind {
    "double" -> option.or(lines.double_entry, lines.entry)
    "take" -> lines.answer_entry
    _ -> lines.entry
  }
}

type Lines {
  Lines(
    entry: Option(Int),
    double_entry: Option(Int),
    answer_entry: Option(Int),
  )
}

fn lines_decoder() -> decode.Decoder(Lines) {
  use entry <- decode.optional_field("entry", None, decode.optional(decode.int))
  use double_entry <- decode.optional_field(
    "double_entry",
    None,
    decode.optional(decode.int),
  )
  use answer_entry <- decode.optional_field(
    "answer_entry",
    None,
    decode.optional(decode.int),
  )
  decode.success(Lines(entry, double_entry, answer_entry))
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
        "double" -> "White to play. Double?"
        "take" -> "White is doubled. Take?"
        _ -> "White to play the roll. What's your play?"
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
