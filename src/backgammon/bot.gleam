//// Sage, the bot that plays a seat.
////
//// Pure. It is handed the game as it stands and the analysis engine as a
//// closure (`game.Ask`), and answers with the actions to take, in the order
//// to take them -- the same `{"name", "params"}` objects a browser sends. The
//// platform owns the socket, the timeout and the retries; nothing here knows
//// what a room is.
////
//// **Why the review route.** Every ask goes to `POST /backgammon/review`
//// with a single turn, not to `/moves` and `/cube`. The single-position
//// routes validate the board with `board[0] <= 0`, but bgsage's own format
//// counts the opponent's bar as a plain positive number at index 0 (see
//// `backgammon/engine_board`), so those routes 422 every position with an
//// opposing checker on the bar -- several times a game. The review route has
//// no such check and is the one Oskol already grades finished games through.
//// The cost is that a turn asked with dice also gets a cube analysis it
//// throws away (the engine grades a cube wherever one could be offered),
//// about a third of a second beside seconds of checker play.
////
//// Sage never resigns and never takes a move back -- except that an engine
//// it cannot reach at all ends in an offer to resign (`give_up_after`),
//// because a human owed a move deserves a game they can finish rather than a
//// board that never moves.

import backgammon/board.{type Board, type Color, type Move, Bar, Off, Point}
import backgammon/engine_board.{type Position}
import backgammon/state.{type GameState}
import gamekit/game
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The engine route every ask goes to.
pub const route = "/backgammon/review"

/// How many asks may come back empty before Sage offers the game up instead
/// of thinking again. The platform counts the failures and rides them in;
/// what to do about them is a rule of the game, not of the platform, which
/// is why Elixir never learns the word "resign".
pub const give_up_after = 3

/// What a bot seat does now. `attempts` is how many asks have already failed
/// for this decision.
pub fn decide(
  s: GameState,
  player_id: String,
  ask: game.Ask,
  attempts: Int,
) -> Result(List(Json), String) {
  use color <- result.try(state.color_of(s, player_id))

  case s.resign_offer {
    // A resignation on offer freezes everything else, and answering it is
    // the only thing Sage may do. It needs no engine: the board says what a
    // win would be worth right now.
    Some(state.ResignOffer(_, stakes)) ->
      case state.must_answer_resign(s, player_id) {
        True -> Ok([answer_resign(s, color, stakes)])
        False -> Ok([])
      }
    None ->
      case s.phase {
        state.BetweenGames(_, _) ->
          case state.can_ready(s, player_id) {
            True -> Ok([simple("ready")])
            False -> Ok([])
          }
        state.Doubled(by) if by != color ->
          answer_double(s, color, ask, attempts)
        state.Rolling(_) ->
          case state.can_roll(s, player_id) {
            True -> roll_or_double(s, player_id, color, ask, attempts)
            False -> Ok([])
          }
        state.Moving(mover, _) if mover == color ->
          play_turn(s, color, ask, attempts)
        // Somebody else's move, or a match that is over: nothing to do.
        _ -> Ok([])
      }
  }
}

// ---------- The decisions ----------

/// An offer to resign is worth taking when it hands over at least what
/// winning from here would: a single offered on a position that is a gammon
/// leaves two points on the table, so that one is declined and Sage plays on.
fn answer_resign(s: GameState, color: Color, stakes: board.WinKind) -> Json {
  let standing = board.win_kind(s.turn_board, color)
  case board.points_for(stakes) >= board.points_for(standing) {
    True -> simple("accept_resign")
    False -> simple("decline_resign")
  }
}

/// Before the roll: double, or just roll. The engine is asked only where it
/// would grade a double at all -- a dead cube is Oskol's to allow and not
/// something the engine has an opinion about.
fn roll_or_double(
  s: GameState,
  player_id: String,
  color: Color,
  ask: game.Ask,
  attempts: Int,
) -> Result(List(Json), String) {
  let position = engine_board.position(s, color)

  case
    state.can_double(s, player_id) && engine_board.engine_can_double(position)
  {
    False -> Ok([simple("roll")])
    True -> {
      use <- unless_given_up(attempts)
      use answered <- result.try(ask(
        route,
        body(s, color, position, None, None),
      ))
      use cube <- result.try(cube_call(answered))
      case cube {
        Some(#(True, _)) -> Ok([simple("double")])
        _ -> Ok([simple("roll")])
      }
    }
  }
}

/// Doubled: take or drop. The cube is judged from the doubler's side, which
/// is the side the engine answers `should_take` for.
fn answer_double(
  s: GameState,
  color: Color,
  ask: game.Ask,
  attempts: Int,
) -> Result(List(Json), String) {
  let doubler = board.opponent(color)
  let position = engine_board.position(s, doubler)

  use <- unless_given_up(attempts)
  use answered <- result.try(ask(route, body(s, doubler, position, None, None)))
  use cube <- result.try(cube_call(answered))
  case cube {
    Some(#(_, False)) -> Ok([simple("drop")])
    // Either the engine says take, or it would not grade this double at all
    // (a dead cube, which Oskol lets a player offer and the engine does
    // not). Dropping one of those would hand over points for nothing.
    _ -> Ok([simple("take")])
  }
}

/// The roll, played: the engine's best play found among the legal sequences,
/// then committed. A roll that plays nothing is committed as it stands.
fn play_turn(
  s: GameState,
  color: Color,
  ask: game.Ask,
  attempts: Int,
) -> Result(List(Json), String) {
  let dice = state.turn_dice(s)

  case state.no_moves(s), board.sequences(s.turn_board, color, dice) {
    True, _ | _, [] -> Ok([simple("play")])
    False, [fallback, ..] as sequences -> {
      use <- unless_given_up(attempts)
      use answered <- result.try(ask(
        route,
        body(
          s,
          color,
          engine_board.position(s, color),
          faces(s),
          Some(engine_board.encode(played(s.turn_board, color, fallback), color)),
        ),
      ))
      use best <- result.try(best_play(answered))
      let chosen = case best {
        Some(target) -> matching(s.turn_board, color, sequences, target)
        // A turn with no dice in the answer: play something legal rather
        // than leave the board standing.
        None -> fallback
      }
      // Anything staged is a think whose actions only half landed; the
      // sequence below is worked out from the board the turn opened on, so
      // the staging has to come off first.
      Ok(
        list.flatten([
          list.repeat(simple("undo"), list.length(s.staged)),
          list.map(chosen, move_action),
          [simple("play")],
        ]),
      )
    }
  }
}

/// The sequence that leaves the board the engine picked. A sequence that
/// encodes to it is the same play by definition; nothing matching means the
/// engine and Oskol disagree about the legal plays, and then the best play
/// available is better than no move at all.
fn matching(
  turn_board: Board,
  color: Color,
  sequences: List(List(Move)),
  target: List(Int),
) -> List(Move) {
  list.find(sequences, fn(sequence) {
    engine_board.encode(played(turn_board, color, sequence), color) == target
  })
  |> result.unwrap(case sequences {
    [first, ..] -> first
    [] -> []
  })
}

/// The board a sequence leaves.
fn played(turn_board: Board, color: Color, sequence: List(Move)) -> Board {
  list.fold(sequence, turn_board, fn(so_far, move) {
    let #(next, _, _) = board.apply_move(so_far, color, move)
    next
  })
}

/// The engine has stopped answering. Rather than a board that never moves,
/// the human is offered the game: accept and it is theirs, decline and Sage
/// keeps trying.
fn unless_given_up(
  attempts: Int,
  next: fn() -> Result(List(Json), String),
) -> Result(List(Json), String) {
  case attempts >= give_up_after {
    True -> Ok([action("resign", [#("stakes", json.string("single"))])])
    False -> next()
  }
}

// ---------- Actions ----------

fn simple(name: String) -> Json {
  action(name, [])
}

fn move_action(move: Move) -> Json {
  action("move", [
    #("from", json.string(board.loc_id(move.from))),
    #("to", json.string(board.loc_id(move.to))),
    #("selected_die", json.string(int.to_string(move.die))),
  ])
}

fn action(name: String, params: List(#(String, Json))) -> Json {
  json.object([#("name", json.string(name)), #("params", json.object(params))])
}

// ---------- The request ----------

/// One turn, as the review route takes it. With no dice it is a cube
/// question and nothing else; with dice it is a checker play, and `played`
/// has to be a legal one for the engine to grade the turn at all (Sage reads
/// only the best play back, so which legal one it is does not matter).
fn body(
  s: GameState,
  mover: Color,
  position: Position,
  dice: Option(#(Int, Int)),
  played_board: Option(List(Int)),
) -> String {
  json.to_string(
    json.object([
      #("jacoby", json.bool(s.config.jacoby)),
      // Luck is a number for a reader, not a decision: asking for it costs
      // another analysis a turn and changes nothing Sage does.
      #("include_luck", json.bool(False)),
      #("top_moves", json.int(1)),
      #(
        "turns",
        json.preprocessed_array([
          json.object([
            #(
              "player",
              json.int(engine_board.seat_index(s, state.player_of(s, mover))),
            ),
            // A turn sent on its own is read as a game's opening roll unless
            // it says where it sits. Only luck cares, and luck is off, but a
            // request that lies about the position is worse than one that
            // does not.
            #("index", json.int(1)),
            #("board", json.array(position.board, json.int)),
            #("cube_value", json.int(position.cube_value)),
            #("cube_owner", json.string(position.cube_owner)),
            #("away1", json.int(position.away1)),
            #("away2", json.int(position.away2)),
            #("is_crawford", json.bool(position.crawford)),
            #("doubled", json.bool(False)),
            #("dice", case dice {
              Some(#(a, b)) -> json.array([a, b], json.int)
              None -> json.null()
            }),
            #("played", case played_board {
              Some(cells) -> json.array(cells, json.int)
              None -> json.null()
            }),
          ]),
        ]),
      ),
    ]),
  )
}

/// The roll's two faces (doubles are two faces, not four).
fn faces(s: GameState) -> Option(#(Int, Int)) {
  case s.last_roll {
    [a, b] -> Some(#(a, b))
    _ -> None
  }
}

// ---------- The answer ----------

/// The cube verdict: `#(should_double, should_take)`, or `None` where the
/// engine graded no cube here.
fn cube_call(answered: String) -> Result(Option(#(Bool, Bool)), String) {
  first_turn(answered, {
    let verdict = {
      use should_double <- decode.field("should_double", decode.bool)
      use should_take <- decode.field("should_take", decode.bool)
      decode.success(#(should_double, should_take))
    }
    decode.one_of(decode.at(["cube", "analysis"], verdict) |> decode.map(Some), [
      decode.success(None),
    ])
  })
}

/// The best play's board, or `None` where the turn carried no move.
fn best_play(answered: String) -> Result(Option(List(Int)), String) {
  first_turn(answered, {
    decode.one_of(
      decode.at(["move", "best", "board"], decode.list(decode.int))
        |> decode.map(Some),
      [decode.success(None)],
    )
  })
}

/// The one turn of a one-turn review.
fn first_turn(answered: String, inner: Decoder(a)) -> Result(a, String) {
  let turns = {
    use turns <- decode.field("turns", decode.list(inner))
    decode.success(turns)
  }

  case json.parse(answered, turns) {
    Ok([turn, ..]) -> Ok(turn)
    Ok([]) -> Error("The engine graded no turns")
    Error(_) -> Error("The engine's answer was not one Sage could read")
  }
}

// ---------- The fake engine (tests) ----------

/// The engine as the suite plays against it: pure, and no network anywhere.
/// It plays the first legal sequence for the dice and never doubles, always
/// takes. The Elixir suite routes its `Req.Test` stub here too, so both
/// layers play the same opponent.
pub fn fake_answer(asked: String, body: String) -> Result(String, String) {
  case asked == route {
    False -> Error("The fake engine knows no route " <> asked)
    True -> {
      let request = {
        use cells <- decode.field("board", decode.list(decode.int))
        use dice <- decode.optional_field(
          "dice",
          None,
          decode.optional(decode.list(decode.int)),
        )
        decode.success(#(cells, dice))
      }
      let turns = {
        use turns <- decode.field("turns", decode.list(request))
        decode.success(turns)
      }

      case json.parse(body, turns) {
        Ok([#(cells, dice), ..]) -> Ok(fake_turn(cells, dice))
        _ -> Error("The fake engine could not read that request")
      }
    }
  }
}

fn fake_turn(cells: List(Int), dice: Option(List(Int))) -> String {
  let move = case dice {
    None -> json.null()
    Some(faces) -> {
      let mover = board.White
      let from = from_engine(cells)
      case board.sequences(from, mover, expand(faces)) {
        [] -> json.null()
        [first, ..] ->
          json.object([
            #(
              "best",
              json.object([
                #(
                  "board",
                  json.array(
                    engine_board.encode(played(from, mover, first), mover),
                    json.int,
                  ),
                ),
              ]),
            ),
          ])
      }
    }
  }

  json.to_string(
    json.object([
      #(
        "turns",
        json.preprocessed_array([
          json.object([
            #("index", json.int(1)),
            #(
              "cube",
              json.object([
                #(
                  "analysis",
                  json.object([
                    #("should_double", json.bool(False)),
                    #("should_take", json.bool(True)),
                  ]),
                ),
              ]),
            ),
            #("move", move),
          ]),
        ]),
      ),
    ]),
  )
}

/// Doubles are four moves, not two.
fn expand(faces: List(Int)) -> List(Int) {
  case faces {
    [a, b] if a == b -> [a, a, a, a]
    other -> other
  }
}

/// The engine's 26 ints back as a board, read as White's: `engine_board.encode`
/// leaves White's point numbers alone, so White is the mover the round trip
/// is exact for. Checker ids are made up -- an engine board has none, and
/// nothing about a fake answer depends on which checker moved.
fn from_engine(cells: List(Int)) -> Board {
  let at = fn(index: Int) {
    list.drop(cells, index) |> list.first |> result.unwrap(0)
  }
  let points = fn(sign: Int) {
    list.range(1, 24)
    |> list.flat_map(fn(point) {
      list.repeat(Point(point), int.max(0, sign * at(point)))
    })
  }
  let side = fn(color: Color, on_points: List(board.Loc), bar: Int) {
    let held = list.flatten([on_points, list.repeat(Bar, int.max(0, bar))])
    list.flatten([held, list.repeat(Off, 15 - list.length(held))])
    |> list.index_map(fn(loc, index) {
      #(board.prefix(color) <> int.to_string(index + 1), #(color, loc))
    })
  }

  board.Board(
    checkers: dict.from_list(list.append(
      side(board.White, points(1), at(25)),
      side(board.Black, points(-1), at(0)),
    )),
  )
}
