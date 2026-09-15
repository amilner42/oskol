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
//// never in the engine's legal list, so the whole review 422s.
////
//// The turns come from replaying the room's seed and action log through
//// the same gamekit calls the rehydrator uses (`gamekit/replay`), split at
//// game boundaries so every game of a match is its own list. Nothing here
//// talks to the engine: this only says what to ask.

import backgammon/board.{type Board, type Color, Black, Point, White}
import backgammon/engine
import backgammon/game as backgammon
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
    /// The dice were picked, not rolled (the "Pick dice" twist): whatever
    /// the engine says about luck means nothing for this turn.
    picked: Bool,
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
pub fn games(log: replay.Log) -> Result(List(GameTurns), String) {
  use #(acc, running) <- result.try(replay.fold(
    backgammon.game(),
    log,
    start,
    step,
  ))
  let finished = case instance.running_outcome(running) {
    game.Finished(_) -> True
    game.Ongoing -> False
  }
  Ok(case acc.over, acc.open {
    True, _ -> list.reverse(acc.games)
    // Between the games of a match: the last one is already closed, and
    // the next has not begun.
    False, False -> list.reverse(acc.games)
    // Over but not by the rules: a clock ran out. The game in progress
    // ends where it stood.
    False, True -> list.reverse(close(acc, finished, acc.last_index).games)
  })
}

/// One game of a room by number.
pub fn game(log: replay.Log, number: Int) -> Result(GameTurns, String) {
  use all <- result.try(games(log))
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
    picked: Bool,
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
    picked: False,
    double_entry: None,
    answer_entry: None,
  )
}

fn with_dice(p: Pending, s: GameState) -> Pending {
  let dice = case s.last_roll {
    [a, b] -> Some(#(a, b))
    _ -> None
  }
  Pending(..p, dice: dice, picked: s.last_roll_picked)
}

fn seat_index(s: GameState, player_id: String) -> Int {
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
    Some(engine.Roll), pending | Some(engine.Pick(_, _)), pending ->
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
        picked: p.picked,
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

// ---------- The request ----------

/// The body of `POST /backgammon/review` for one game: luck and the top
/// five moves. The search depth is the service's own default (4-ply for
/// moves and the cube, since 2026-09-15), so it is set in one place, the
/// engine, and the answer says which it used (`levels`).
pub fn request_json(g: GameTurns) -> Json {
  json.object([
    #("jacoby", json.bool(g.jacoby)),
    #("top_moves", json.int(5)),
    #("include_luck", json.bool(True)),
    #("turns", json.array(g.turns, turn_json)),
  ])
}

pub fn turn_json(turn: Turn) -> Json {
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
  ])
}
