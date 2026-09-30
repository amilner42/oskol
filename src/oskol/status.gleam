//// The status page's proof that the engine is really there: one real
//// position out of a real game, sent to the engine now and answered now.
////
//// `/status` used to read UP for anything that answered `GET /health` --
//// which a twelve-line stub does, and did, for most of an evening, while
//// the engine it stood in front of was not running (the Aveline doc
//// `bgsage-gotchas`). A board with the engine's own best play written
//// under it cannot be answered that way: the play has to be right.
////
//// Pure. A stored question in, a request body out; the engine's answer
//// in, the page's JSON out. Choosing the position, the asking and the
//// caching are Elixir's (`OskolWeb.StatusController`).
////
//// **Move questions only.** A take is stored turned around
//// (`puzzles.flip`) and a double is graded from the doubler's side, so
//// neither becomes a lone turn without care -- and neither is a board
//// with dice on it, which is the thing worth showing.
////
//// **Why the review route** and not `/backgammon/moves`: the same reason
//// the bot takes it (`backgammon/bot`). The single-position routes
//// validate the board with `board[0] <= 0` and so 422 every position with
//// an opposing checker on the bar.

import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import oskol/puzzles.{type Owner, type Question, Centered, Mover, Opponent}

/// The engine route the page asks on. A function rather than a constant
/// because the caller is Elixir, and Gleam inlines a constant away.
pub fn route() -> String {
  "/backgammon/review"
}

/// How many plays the page lists under the board.
const top_moves = 3

// ---------- Asking ----------

/// The body that asks the engine what to play here.
pub fn request(q: Question) -> String {
  json.to_string(
    json.object([
      #("jacoby", json.bool(q.jacoby)),
      // Luck is a number about a roll that already happened. The page is
      // asking what to do with the roll, and asking for luck as well costs
      // another analysis.
      #("include_luck", json.bool(False)),
      #("top_moves", json.int(top_moves)),
      #(
        "turns",
        json.preprocessed_array([
          json.object([
            // A move question is stored from the mover's own side, so the
            // mover is the first seat and the board needs no turning.
            #("player", json.int(0)),
            // A turn sent on its own is read as a game's opening roll
            // unless it says where it sits.
            #("index", json.int(1)),
            #("board", json.array(q.board, json.int)),
            #("cube_value", json.int(q.cube_value)),
            #("cube_owner", json.string(cube_owner(q.cube_owner))),
            #("away1", json.int(q.away_mover)),
            #("away2", json.int(q.away_opponent)),
            #("is_crawford", json.bool(q.crawford)),
            #("doubled", json.bool(False)),
            #("dice", case q.dice {
              Some(#(high, low)) -> json.array([high, low], json.int)
              None -> json.null()
            }),
            // Nothing has been played: this is the question, not a grade.
            #("played", json.null()),
          ]),
        ]),
      ),
    ]),
  )
}

/// The engine's word for who holds the cube. `puzzles` names it from the
/// solver's side (`mover`), the engine from the seat's (`player`).
fn cube_owner(owner: Owner) -> String {
  case owner {
    Centered -> "centered"
    Mover -> "player"
    Opponent -> "opponent"
  }
}

// ---------- Reading ----------

/// What the engine said, as the page's JSON: the plays it likes, best
/// first, with the depth it searched at and how long it took.
///
/// Read here rather than with `oskol/reviews/report`, which wants a whole
/// graded turn -- and a turn nobody has played has no `played` move for it
/// to decode. The bot reads the same answer itself for the same reason
/// (`backgammon/bot`).
pub fn read(body: String) -> Result(String, String) {
  use answer <- result.try(
    json.parse(body, answer_decoder())
    |> result.replace_error("The engine's answer did not read as one"),
  )
  case answer.plays {
    [] -> Error("The engine named no play")
    plays ->
      Ok(
        json.to_string(
          json.object([
            #("level", json.string(answer.level)),
            #("took_ms", json.int(answer.took_ms)),
            #("plays", json.array(plays, play_json)),
          ]),
        ),
      )
  }
}

type Answer {
  Answer(plays: List(Play), level: String, took_ms: Int)
}

type Play {
  Play(notation: String, equity: Float, behind: Float, win: Float)
}

fn play_json(p: Play) -> Json {
  json.object([
    #("notation", json.string(p.notation)),
    #("equity", json.float(p.equity)),
    // Best-relative, so zero for the best play and negative behind it.
    #("behind", json.float(p.behind)),
    #("win", json.float(p.win)),
  ])
}

fn answer_decoder() -> Decoder(Answer) {
  use turns <- decode.field("turns", decode.list(turn_decoder()))
  use level <- decode.optional_field("levels", "", moves_level())
  use took_ms <- decode.optional_field("timing_ms", 0, whole())
  decode.success(Answer(
    // One turn was asked about; a turn that came back without a move
    // leaves nothing to show, which `read` reports rather than drawing an
    // empty answer.
    plays: list.first(turns) |> result.unwrap([]),
    level: level,
    took_ms: took_ms,
  ))
}

fn turn_decoder() -> Decoder(List(Play)) {
  decode.one_of(decode.at(["move"], move_decoder()), [decode.success([])])
}

fn move_decoder() -> Decoder(List(Play)) {
  use best <- decode.field("best", play_decoder())
  use top <- decode.optional_field("top", [], decode.list(play_decoder()))
  // `top` is what the request asked for and `best` is its first. An engine
  // that sent only the one still has something to show.
  decode.success(case top {
    [] -> [best]
    plays -> plays
  })
}

fn play_decoder() -> Decoder(Play) {
  use notation <- decode.field("notation", decode.string)
  use equity <- decode.field("equity", number())
  use behind <- decode.optional_field("equity_diff", 0.0, number())
  // The chances are worth printing but not worth failing over: a play
  // with a name and an equity is still an answer.
  use win <- decode.optional_field("probs", 0.0, win_chance())
  decode.success(Play(notation, equity, behind, win))
}

fn moves_level() -> Decoder(String) {
  decode.one_of(decode.at(["moves"], decode.string), [decode.success("")])
}

fn win_chance() -> Decoder(Float) {
  decode.one_of(decode.at(["win"], number()), [decode.success(0.0)])
}

/// JSON numbers from Python may be written as 0 or 0.0.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn whole() -> Decoder(Int) {
  decode.one_of(decode.int, [decode.float |> decode.map(float.round)])
}
