//// A finished backgammon game, turn by turn, as the analysis engine takes
//// it (`POST /backgammon/review` on the oskol-analysis service).
////
//// The engine speaks one board format: 26 ints from the perspective of the
//// player on roll. Indexes 1..24 are points counted from the mover's side
//// (their checkers positive, the opponent's negative; they move 24 -> 1
//// and bear off past 1), 25 is the mover's bar and 0 the opponent's bar.
//// Borne-off checkers are not stored. Oskol numbers points so that White
//// moves 24 -> 1, so for White a point keeps its number and for Black
//// point p is index 25 - p.
////
//// Both bars are plain counts, never negative: that is bgsage's own
//// format (`board[0]` "opponent checkers on bar (>= 0)"), and the boards
//// the engine generates for a played move say so -- a hit shows up as +1
//// at index 0. The service's README and doc (2026-09) say index 0 is
//// negative; they are wrong, and a `played` board signed that way is
//// never in the engine's legal list, so the whole review 422s. (The
//// single-position routes `/moves` and `/cube` validate the board the wrong
//// way round and reject a positive index 0 outright, which is why
//// `backgammon/bot` asks its questions through `/review` instead.)
////
//// The turns come from replaying the room's seed and action log through
//// the same gamekit calls the rehydrator uses (`gamekit/replay`), split at
//// game boundaries so every game of a match is its own list. Nothing here
//// talks to the engine: this only says what to ask.

import backgammon/board.{type Board, type Color, Black, Point, White}
import backgammon/engine
import backgammon/record
import backgammon/state.{type GameState}
import gamekit/game
import gamekit/instance
import gamekit/replay
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// How the opponent answered a double.
pub type Answer {
  Took
  Passed
}

/// The position a turn starts from, as the engine takes it: everything
/// relative to the player on roll.
pub type Position {
  Position(
    board: List(Int),
    cube_value: Int,
    /// "centered", "player" (the mover owns it) or "opponent".
    cube_owner: String,
    /// Points the mover and the opponent still need; both 0 in a money
    /// game (unlimited play).
    away1: Int,
    away2: Int,
    crawford: Bool,
  )
}

/// One turn of one game.
pub type Turn {
  Turn(
    /// Seat index of the player on roll: 0 is the first seat (White).
    player: Int,
    player_id: String,
    position: Position,
    /// A double offered at the start of the turn, and the answer.
    double: Option(Answer),
    /// The roll. None when a passed double ended the turn first.
    dice: Option(#(Int, Int)),
    /// The board after the move, from the mover's side; the board the turn
    /// began on when the roll could play nothing (see `danced`). None when
    /// there was no roll (see `double`).
    played: Option(List(Int)),
    /// The action-log index of the entry that closed the turn.
    log_index: Int,
    /// Where the turn sits in its game's record (`record.by_game`, the
    /// entries the room's `/record` lists for that game): the index of the
    /// committed `Turn` entry, of the `Double` entry, and of the answer
    /// (`Take` or `Drop`). Each is None where the turn has no such entry, or
    /// where the engine is not asked about it (a double it cannot grade).
    /// A page puts the engine's verdicts on the lines they are about with
    /// these, never by counting.
    entry: Option(Int),
    double_entry: Option(Int),
    answer_entry: Option(Int),
  )
}

/// One game of a room.
pub type GameTurns {
  GameTurns(
    /// 1 for the first game of a room, counting up through a match.
    number: Int,
    /// Over: won, dropped, resigned or lost on time. The game still being
    /// played is listed too, unfinished.
    finished: Bool,
    /// Gammons count only once the cube is turned (unlimited play).
    jacoby: Bool,
    turns: List(Turn),
  )
}

// ---------- The board ----------

/// The engine's 26-int board for `mover`, who is on roll.
pub fn encode(b: Board, mover: Color) -> List(Int) {
  let opponent = board.opponent(mover)
  let points =
    list.range(1, 24)
    |> list.map(fn(index) {
      let point = oskol_point(mover, index)
      board.count(b, mover, Point(point))
      - board.count(b, opponent, Point(point))
    })
  list.flatten([
    [board.on_bar(b, opponent)],
    points,
    [board.on_bar(b, mover)],
  ])
}

/// The engine's board read back into Oskol's, the way the record keeps a
/// position: each colour's checkers on points 1..24, on the bar and borne
/// off, and its pip count, `#(white, black)`. `mover` is the player the
/// board is drawn for (the one on roll). The inverse of `encode`, for the
/// boards the engine sends back (a candidate move's result); Error when the
/// list is not a board.
pub fn decode(
  engine_board: List(Int),
  mover: Color,
) -> Result(#(record.Side, record.Side), Nil) {
  case engine_board {
    [opponent_bar, ..rest] ->
      case list.length(rest) == 25 {
        False -> Error(Nil)
        True -> {
          let points = list.take(rest, 24)
          let mover_bar = list.drop(rest, 24) |> list.first |> result.unwrap(0)
          // Oskol point p (1..24) holds what engine index `index_of(p)` does.
          let at = fn(p: Int) {
            list.drop(points, engine_index(mover, p) - 1)
            |> list.first
            |> result.unwrap(0)
          }
          let counts = fn(sign: Int) {
            list.range(1, 24)
            |> list.map(fn(p) { int.max(0, sign * at(p)) })
          }
          let side = fn(color: Color, counts: List(Int), bar: Int) {
            let on_points = int.sum(counts)
            record.Side(
              points: counts,
              bar: bar,
              off: 15 - on_points - bar,
              pips: 25
                * bar
                + int.sum(
                list.index_map(counts, fn(n, i) {
                  n * board.pip_distance(color, i + 1)
                }),
              ),
            )
          }
          let mine = side(mover, counts(1), mover_bar)
          let theirs = side(board.opponent(mover), counts(-1), opponent_bar)
          Ok(case mover {
            White -> #(mine, theirs)
            Black -> #(theirs, mine)
          })
        }
      }
    [] -> Error(Nil)
  }
}

/// Where the mover's checkers landed going from one engine board to
/// another: every Oskol point that gained checkers of theirs, once per
/// checker it gained, low point first -- the record's `landed` for a move
/// the engine proposes. Checkers borne off land nowhere.
pub fn landings(from: List(Int), to: List(Int), mover: Color) -> List(Int) {
  list.range(1, 24)
  |> list.flat_map(fn(index) {
    let before = int.max(0, nth(from, index))
    let after = int.max(0, nth(to, index))
    list.repeat(oskol_point(mover, index), int.max(0, after - before))
  })
  |> list.sort(int.compare)
}

fn nth(values: List(Int), index: Int) -> Int {
  list.drop(values, index) |> list.first |> result.unwrap(0)
}

/// The engine index 1..24 of Oskol point `p` for this mover.
fn engine_index(mover: Color, p: Int) -> Int {
  case mover {
    White -> p
    Black -> 25 - p
  }
}

/// The Oskol point behind engine index 1..24 for this mover.
fn oskol_point(mover: Color, index: Int) -> Int {
  case mover {
    White -> index
    Black -> 25 - index
  }
}

/// The position `mover` is on roll in: the board as it stood when the turn
/// began (never a staged move), the cube and the match score.
pub fn position(s: GameState, mover: Color) -> Position {
  let mover_id = state.player_of(s, mover)
  let opponent_id = state.player_of(s, board.opponent(mover))
  let target = s.config.target
  let #(away1, away2) = case target > 0 {
    True -> #(
      target - state.score_of(s, mover_id),
      target - state.score_of(s, opponent_id),
    )
    False -> #(0, 0)
  }
  let owner = case s.cube_owner {
    None -> "centered"
    Some(color) if color == mover -> "player"
    Some(_) -> "opponent"
  }
  Position(
    board: encode(s.turn_board, mover),
    cube_value: s.cube_value,
    cube_owner: owner,
    away1: away1,
    away2: away2,
    crawford: s.crawford,
  )
}

/// Could the engine grade a double here? It will not take one it thinks
/// illegal: in the Crawford game, on a cube the opponent owns, or on a
/// dead cube (a match where the cube already covers what the doubler
/// needs). Oskol lets that last one be offered; it is the one difference.
pub fn engine_can_double(p: Position) -> Bool {
  let money = p.away1 == 0 && p.away2 == 0
  !p.crawford
  && p.cube_owner != "opponent"
  && { money || p.cube_value < p.away1 }
}

// ---------- The turns ----------

/// Every game of a room, in order, replayed from its log.
///
/// `definition` is the backgammon contract itself. It is passed in rather
/// than imported because the contract now asks this module what a committed
/// turn is (`committed_json`), so this module cannot also be the one that
/// knows where the contract lives.
pub fn games(
  definition: game.Game(GameState, engine.Action),
  log: replay.Log,
) -> Result(List(GameTurns), String) {
  games_with_record(definition, log) |> result.map(fn(both) { both.0 })
}

/// Every game of a room and the record the room ended up holding, from one
/// replay. The record is what `GET /record` serves; splitting it into the
/// rows a finished game is stored as costs nothing here, because the replay
/// that produced it has already been paid for.
pub fn games_with_record(
  definition: game.Game(GameState, engine.Action),
  log: replay.Log,
) -> Result(#(List(GameTurns), Option(Json)), String) {
  use #(acc, running) <- result.try(replay.fold(definition, log, start, step))
  let record = instance.record(instance.erase(running))
  let finished = case instance.running_outcome(running) {
    game.Finished(_) -> True
    game.Ongoing -> False
  }
  let games = case acc.over, acc.open {
    True, _ -> list.reverse(acc.games)
    // Between the games of a match: the last one is already closed, and
    // the next has not begun.
    False, False -> list.reverse(acc.games)
    // Over but not by the rules: a clock ran out. The game in progress
    // ends where it stood.
    False, True -> list.reverse(close(acc, finished, acc.last_index).games)
  }
  Ok(#(games, record))
}

/// One game of a room by number.
pub fn game(
  definition: game.Game(GameState, engine.Action),
  log: replay.Log,
  number: Int,
) -> Result(GameTurns, String) {
  use all <- result.try(games(definition, log))
  list.find(all, fn(g) { g.number == number })
  |> result.replace_error("No game " <> int.to_string(number))
}

type Offer {
  NoDouble
  Offered
  Answered(Answer)
}

/// A turn under way.
type Pending {
  Pending(
    color: Color,
    player: Int,
    player_id: String,
    position: Position,
    offer: Offer,
    dice: Option(#(Int, Int)),
    double_entry: Option(Int),
    answer_entry: Option(Int),
  )
}

type Acc {
  Acc(
    games: List(GameTurns),
    number: Int,
    jacoby: Bool,
    turns: List(Turn),
    pending: Option(Pending),
    /// The match is over; nothing follows.
    over: Bool,
    /// A game is under way: begun and not yet closed. False between the
    /// games of a match, until both players are ready for the next.
    open: Bool,
    /// The last log index seen.
    last_index: Int,
  )
}

fn start(s: GameState) -> Acc {
  Acc(
    games: [],
    number: s.game_number,
    jacoby: s.config.jacoby,
    turns: [],
    pending: opening(s),
    over: False,
    open: True,
    last_index: -1,
  )
}

/// A game opens straight into the first mover's turn: the opening roll is
/// part of starting it, not an action anyone takes.
fn opening(s: GameState) -> Option(Pending) {
  case s.phase {
    state.Moving(color, _) -> Some(pending_for(s, color) |> with_dice(s))
    _ -> None
  }
}

fn pending_for(s: GameState, color: Color) -> Pending {
  let player_id = state.player_of(s, color)
  Pending(
    color: color,
    player: seat_index(s, player_id),
    player_id: player_id,
    position: position(s, color),
    offer: NoDouble,
    dice: None,
    double_entry: None,
    answer_entry: None,
  )
}

fn with_dice(p: Pending, s: GameState) -> Pending {
  let dice = case s.last_roll {
    [a, b] -> Some(#(a, b))
    _ -> None
  }
  Pending(..p, dice: dice)
}

/// Which seat this player sits in: 0 is the first seat (White). The engine
/// names the player on roll by seat index, and a turn asked one at a time
/// (`backgammon/bot`) needs the same number a whole review's turn carries.
pub fn seat_index(s: GameState, player_id: String) -> Int {
  s.order
  |> list.index_map(fn(id, i) { #(id, i) })
  |> list.find(fn(entry) { entry.0 == player_id })
  |> result.map(fn(entry) { entry.1 })
  |> result.unwrap(0)
}

fn step(acc: Acc, t: replay.Transition(GameState, engine.Action)) -> Acc {
  let before = t.before
  let after = t.after
  let acc = Acc(..acc, last_index: t.index)
  let acc = case t.action, acc.pending {
    Some(engine.Double), _ ->
      case before.phase {
        state.Rolling(color) ->
          Acc(
            ..acc,
            pending: Some(
              Pending(
                ..pending_for(before, color),
                offer: Offered,
                double_entry: Some(next_entry(before)),
              ),
            ),
          )
        _ -> acc
      }
    Some(engine.Take), Some(p) ->
      Acc(
        ..acc,
        pending: Some(
          Pending(
            ..p,
            offer: Answered(Took),
            answer_entry: Some(next_entry(before)),
          ),
        ),
      )
    Some(engine.Drop), Some(p) ->
      emit(
        acc,
        Pending(
          ..p,
          offer: Answered(Passed),
          dice: None,
          answer_entry: Some(next_entry(before)),
        ),
        None,
        None,
        t.index,
      )
    Some(engine.Roll), pending ->
      case before.phase {
        state.Rolling(color) -> {
          let p = option.unwrap(pending, pending_for(before, color))
          Acc(..acc, pending: Some(with_dice(p, after)))
        }
        _ -> acc
      }
    // The committed board. A roll that played nothing commits the board it
    // started on, and that is what the engine is sent: it lists a dance as
    // the one "move" that leaves the board as it was (bgsage's
    // possible_moves), and 422s a turn with dice and no played board.
    Some(engine.Play), Some(p) ->
      emit(
        acc,
        p,
        Some(encode(before.board, p.color)),
        Some(next_entry(before)),
        t.index,
      )
    _, _ -> acc
  }
  // A game ends the moment it is won: into the pause before the next game
  // of a match (which waits for both players to be ready), or the end of
  // the match. The next game begins when its number turns over.
  let ended =
    { between(after) && !between(before) }
    || { is_over(after) && !is_over(before) }
    || { after.game_number != before.game_number && acc.open }
  let acc = case ended {
    True -> {
      let closed = close(acc, True, t.index)
      Acc(..closed, over: is_over(after), open: False)
    }
    False -> acc
  }
  let acc = case after.game_number != acc.number {
    True -> Acc(..acc, number: after.game_number, open: True)
    False -> acc
  }
  case acc.pending, acc.over {
    None, False -> Acc(..acc, pending: opening(after))
    _, _ -> acc
  }
}

/// The index the next record entry takes within the game it belongs to:
/// how many entries that game already has (the record is kept newest first,
/// and a game's entries follow the previous game's `GameOver`).
fn next_entry(s: GameState) -> Int {
  s.record
  |> list.take_while(fn(e) {
    case e {
      record.GameOver(..) -> False
      _ -> True
    }
  })
  |> list.length
}

fn between(s: GameState) -> Bool {
  case s.phase {
    state.BetweenGames(..) -> True
    _ -> False
  }
}

fn is_over(s: GameState) -> Bool {
  case s.phase {
    state.Finished(_) -> True
    _ -> False
  }
}

/// A turn played to its end.
fn emit(
  acc: Acc,
  p: Pending,
  played: Option(List(Int)),
  entry: Option(Int),
  index: Int,
) -> Acc {
  let turns = case settle(p, played, entry, index) {
    Some(turn) -> [turn, ..acc.turns]
    None -> acc.turns
  }
  Acc(..acc, turns: turns, pending: None)
}

/// Close the current game. A turn cut off by the end (a resignation, a
/// clock) keeps only what was decided: an answered double stands, dice
/// that were never played do not. A game still being played keeps only
/// its complete turns.
fn close(acc: Acc, finished: Bool, index: Int) -> Acc {
  let cut_off = case finished, acc.pending {
    True, Some(Pending(offer: Answered(_), ..) as p) ->
      settle(Pending(..p, dice: None), None, None, index)
    _, _ -> None
  }
  let turns = case cut_off {
    Some(turn) -> [turn, ..acc.turns]
    None -> acc.turns
  }
  let done =
    GameTurns(
      number: acc.number,
      finished: finished,
      jacoby: acc.jacoby,
      turns: list.reverse(turns),
    )
  Acc(..acc, games: [done, ..acc.games], turns: [], pending: None)
}

/// The turn as the engine will take it, or None when there is nothing it
/// could grade. A double the engine thinks illegal (a dead cube) is folded
/// away: taken, the turn is played on the doubled cube the taker now owns;
/// passed, the game simply ended.
fn settle(
  p: Pending,
  played: Option(List(Int)),
  entry: Option(Int),
  index: Int,
) -> Option(Turn) {
  let answer = case p.offer {
    Answered(answer) -> Some(answer)
    _ -> None
  }
  let #(position, answer) = case answer {
    Some(Took) ->
      case engine_can_double(p.position) {
        True -> #(p.position, answer)
        False -> #(
          Position(
            ..p.position,
            cube_value: p.position.cube_value * 2,
            cube_owner: "opponent",
          ),
          None,
        )
      }
    Some(Passed) ->
      case engine_can_double(p.position) {
        True -> #(p.position, answer)
        False -> #(p.position, None)
      }
    None -> #(p.position, None)
  }
  let played = case p.dice {
    Some(_) -> played
    None -> None
  }
  case answer, p.dice {
    None, None -> None
    _, _ ->
      Some(Turn(
        player: p.player,
        player_id: p.player_id,
        position: position,
        double: answer,
        dice: p.dice,
        played: played,
        log_index: index,
        entry: entry,
        // A double folded away is no decision of the engine's: nothing of
        // its verdict to place.
        double_entry: option.then(answer, fn(_) { p.double_entry }),
        answer_entry: option.then(answer, fn(_) { p.answer_entry }),
      ))
  }
}

/// The roll could play nothing. Every real move changes the board, so a
/// played board equal to the one the turn began on is a dance.
pub fn danced(turn: Turn) -> Bool {
  turn.dice != None && turn.played == Some(turn.position.board)
}

// ---------- One turn, as it is committed ----------

/// The turn this step committed, if it committed one: exactly the `Turn`
/// the end-of-game replay produces for it, read off the state the action
/// landed on instead of folded out of the whole log.
///
/// That equality is the whole point. A turn graded when it is played is
/// only ever a cache of what the review would have asked, and the cache is
/// keyed on the request; so a commit that built the question even slightly
/// differently would simply never be found again. `analysis_test` holds the
/// two to each other turn for turn over seeded logs.
///
/// Only `play` and `drop` commit a turn: a roll, a double and a take are
/// half of one, staging is private, and `undo` only unstages -- there is no
/// takeback after a commit, so no grade is ever invalidated.
///
/// `log_index` is the one thing a commit cannot know: it is where the entry
/// sits in the room's action log, which the game never sees. Nothing the
/// engine is sent carries it (`turn_json`), so a grade keyed on the request
/// is none the worse; it is -1 here and the replay's own number there.
pub fn committed(
  before: GameState,
  action: engine.Action,
  _after: GameState,
) -> Option(Turn) {
  case action, before.phase {
    // The committed board, as `step` reads it: the staged moves are on
    // `board` and the board the turn began on is `turn_board`. A roll that
    // played nothing commits the board it started on, which is the same
    // list, and that is what the engine wants for a dance.
    engine.Play, state.Moving(color, _) -> {
      let entries = game_entries(before)
      settle(
        pending_of(before, color, entries),
        Some(encode(before.board, color)),
        Some(list.length(entries)),
        -1,
      )
    }
    // A passed double ends the turn before the dice: the graded decision is
    // the doubler's, and the dropper is the one answering it.
    engine.Drop, state.Doubled(by) -> {
      let entries = game_entries(before)
      let p = pending_of(before, by, entries)
      settle(
        Pending(
          ..p,
          offer: Answered(Passed),
          dice: None,
          answer_entry: Some(list.length(entries)),
        ),
        None,
        None,
        -1,
      )
    }
    _, _ -> None
  }
}

/// The turn this step committed, as the platform carries it off the room:
/// which game of the room it belongs to, and the exact body of the one-turn
/// `POST /backgammon/review` that grades it.
///
/// The body crosses as **text** because it is what a cached grade is found
/// by: the platform hashes and posts the very bytes built here, and the
/// end-of-game job builds the same bytes again to look the answer up
/// (`one_turn_request`). Nothing re-serialises it on the way, so nothing
/// can quietly reorder a key and turn every hit into a miss.
///
/// It holds only what both players saw when the turn was played: the board
/// it began on, the dice, the board it left, the cube and the score.
pub fn committed_json(
  before: GameState,
  action: engine.Action,
  after: GameState,
) -> Option(Json) {
  case committed(before, action, after) {
    None -> None
    Some(turn) -> {
      let index = turn_index(game_entries(before))
      Some(
        json.object([
          #("game_number", json.int(before.game_number)),
          #("index", json.int(index)),
          #(
            "body",
            json.string(
              json.to_string(one_turn_request(turn, index, before.config.jacoby)),
            ),
          ),
        ]),
      )
    }
  }
}

/// The turn under way, rebuilt from the state the commit landed on.
///
/// Everything but the cube is where it was when the turn began:
/// `turn_board` is the board before any move was staged, and the score and
/// the Crawford flag only move between games. The cube is the catch -- a
/// double that was taken turns it before the mover rolls, so the state now
/// holds twice the value owned by the taker -- and the engine grades the
/// decision on what the doubler was looking at. `settle` then folds a
/// double the engine will not take (a dead cube) exactly as the replay
/// does.
fn pending_of(
  s: GameState,
  color: Color,
  entries: List(record.Entry),
) -> Pending {
  let turn = turn_entries(entries)
  let double =
    entry_index(turn, fn(e) {
      case e {
        record.Double(..) -> True
        _ -> False
      }
    })
  let took =
    entry_index(turn, fn(e) {
      case e {
        record.Take(..) -> True
        _ -> False
      }
    })
  let position = position(s, color)
  let position = case took {
    None -> position
    // A cube worth more than 1 has been turned before, and only its owner
    // may turn it again, so the cube the doubler held was their own; a
    // 1-cube has never been turned and was centred.
    Some(_) -> {
      let value = position.cube_value / 2
      Position(..position, cube_value: value, cube_owner: case value {
        1 -> "centered"
        _ -> "player"
      })
    }
  }
  Pending(
    ..pending_for(s, color),
    position: position,
    offer: case took {
      Some(_) -> Answered(Took)
      None ->
        case double {
          Some(_) -> Offered
          None -> NoDouble
        }
    },
    dice: dice_of(s),
    double_entry: double,
    answer_entry: took,
  )
}

/// The dice of the turn under way: `last_roll`, as `with_dice` reads it.
fn dice_of(s: GameState) -> Option(#(Int, Int)) {
  case s.last_roll {
    [a, b] -> Some(#(a, b))
    _ -> None
  }
}

/// This game's record entries so far, newest first: everything since the
/// previous game's `GameOver` (the record is kept newest first).
fn game_entries(s: GameState) -> List(record.Entry) {
  list.take_while(s.record, fn(e) {
    case e {
      record.GameOver(..) -> False
      _ -> True
    }
  })
}

/// The entries of the turn under way -- everything since the last committed
/// turn -- each with the index it holds in this game's record, which is
/// what a page puts a verdict on a line by (`Turn.entry`).
fn turn_entries(entries: List(record.Entry)) -> List(#(Int, record.Entry)) {
  let total = list.length(entries)
  entries
  |> list.index_map(fn(e, i) { #(total - 1 - i, e) })
  |> list.take_while(fn(pair) {
    case pair.1 {
      record.Turn(..) -> False
      _ -> True
    }
  })
}

fn entry_index(
  entries: List(#(Int, record.Entry)),
  matching: fn(record.Entry) -> Bool,
) -> Option(Int) {
  list.find(entries, fn(pair) { matching(pair.1) })
  |> result.map(fn(pair) { pair.0 })
  |> option.from_result
}

/// Where the turn being committed sits in its game, counting from 0: how
/// many of its turns the engine has already been asked about.
///
/// Every committed turn is a `record.Turn`, and the one graded turn that is
/// not -- a passed double -- ends the game, so it can only ever be the
/// last. Counting the record's turns therefore gives the same number the
/// engine would infer from a whole-game request, which is what the luck of
/// the opening roll turns on.
fn turn_index(entries: List(record.Entry)) -> Int {
  list.count(entries, fn(e) {
    case e {
      record.Turn(..) -> True
      _ -> False
    }
  })
}

// ---------- The request ----------

/// The body of `POST /backgammon/review` for one game: luck, the top five
/// moves described in full, and every legal play's board and cost besides.
/// The search depth is the service's own default (4-ply for moves and the
/// cube, since 2026-09-15), so it is set in one place, the engine, and the
/// answer says which it used (`levels`).
///
/// `all_results` costs the engine nothing -- it evaluates every legal play
/// anyway, and `top_moves` only truncates what it writes down -- and it is
/// what lets a puzzle made from this game grade any answer exactly instead
/// of shrugging at one outside the top five. An engine that does not know
/// the flag answers as it always did.
pub fn request_json(g: GameTurns) -> Json {
  request_json_at(g, None, None)
}

/// The same request at a named search depth (`move_level`, `cube_level`,
/// as the engine names them: "4ply"), for asking a game again at the
/// depth its stored answer was graded at. None leaves the engine's own
/// default in charge, as a fresh review does.
pub fn request_json_at(
  g: GameTurns,
  move_level: Option(String),
  cube_level: Option(String),
) -> Json {
  body_json(json.array(g.turns, turn_json), g.jacoby, move_level, cube_level)
}

/// The body for **some** of a game's turns, each with where it sits in that
/// game: what the end-of-game job asks for when grades already stored
/// answer for the rest. One request, however gappy the set.
///
/// The turns are still sent in order, because the engine answers in the
/// order it was asked; the indexes are there because a turn's own place in
/// its game is the one thing about it the engine cannot see from a partial
/// request, and the luck of the opening roll depends on it.
pub fn turns_request(
  turns: List(#(Int, Turn)),
  jacoby: Bool,
  move_level: Option(String),
  cube_level: Option(String),
) -> Json {
  body_json(
    json.array(turns, fn(pair) { turn_json_at(Some(pair.0), pair.1) }),
    jacoby,
    move_level,
    cube_level,
  )
}

/// The body for exactly one turn of a game, at the engine's own default
/// depth. Both the grade taken as a turn is played and the lookup of that
/// grade at the end of the game are built here, and the cache is keyed on
/// these bytes, so this must stay the one place either is written.
pub fn one_turn_request(turn: Turn, index: Int, jacoby: Bool) -> Json {
  turns_request([#(index, turn)], jacoby, None, None)
}

fn body_json(
  turns: Json,
  jacoby: Bool,
  move_level: Option(String),
  cube_level: Option(String),
) -> Json {
  let level = fn(name, value) {
    case value {
      Some(level) -> [#(name, json.string(level))]
      None -> []
    }
  }
  json.object(
    list.flatten([
      [
        #("jacoby", json.bool(jacoby)),
        #("top_moves", json.int(5)),
        #("all_results", json.bool(True)),
        #("include_luck", json.bool(True)),
      ],
      level("move_level", move_level),
      level("cube_level", cube_level),
      [#("turns", turns)],
    ]),
  )
}

pub fn turn_json(turn: Turn) -> Json {
  turn_json_at(None, turn)
}

/// One turn as the engine takes it. `index` is where it sits in its game,
/// sent only where the request is not the whole game in order -- the engine
/// falls back to the turn's place in the request, which is then the same
/// number.
pub fn turn_json_at(index: Option(Int), turn: Turn) -> Json {
  let p = turn.position
  json.object([
    #("player", json.int(turn.player)),
    #("board", json.array(p.board, json.int)),
    #("cube_value", json.int(p.cube_value)),
    #("cube_owner", json.string(p.cube_owner)),
    #("away1", json.int(p.away1)),
    #("away2", json.int(p.away2)),
    #("is_crawford", json.bool(p.crawford)),
    #("doubled", json.bool(turn.double != None)),
    #("response", case turn.double {
      Some(Took) -> json.string("take")
      Some(Passed) -> json.string("pass")
      None -> json.null()
    }),
    #("dice", case turn.dice {
      Some(#(a, b)) -> json.array([a, b], json.int)
      None -> json.null()
    }),
    #("played", case turn.played {
      Some(b) -> json.array(b, json.int)
      None -> json.null()
    }),
    ..case index {
      Some(index) -> [#("index", json.int(index))]
      None -> []
    }
  ])
}
