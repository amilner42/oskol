//// How every roll fares from one board: the engine's per-roll grid, read into
//// a type. Pure.
////
//// The engine answers `{level, equity, rows}` with 21 rows -- one per distinct
//// roll, `a <= b`, doubles first -- each `{dice, weight, equity, best}`. A
//// double is one of the 36 throws and any other roll is two, so the weights
//// sum to 36, and **the rows' weighted mean is the top-level equity**: the
//// headline is the average of the cells beneath it (measured over twenty live
//// 3-ply grids, worst disagreement 7.8e-08; held by
//// `the_rows_weighted_mean_is_the_headline_test`).
////
//// **A cell is the roll's own equity.** Zero is an even position, not an
//// average roll, and the page draws one fixed ramp over every grid: 0
//// neutral, +1 the darkest green, -1 the darkest red, anything beyond
//// clamped. So there are **no bands here**: the colour is a continuous
//// function of a number the client already has, and a seven-bucket
//// quantisation of it would only be a coarser answer to the same question
//// drawn in a second place. What must not drift between the replay, the
//// analysis board and the comparison is the ramp, which is colour and lives
//// with the colour; it is written down in `docs/api.md`.
////
//// What a cell is *not*: a grade. `??` / `?` / `?!` measure a play against the
//// best play, and no cell holds a mistake -- the engine plays the best move
//// for every roll. The only number here a grade could fairly describe is the
//// total of a difference grid, which is the equity between two plays and is
//// graded where plays are graded.
////
//// **Three plies, never two and never four.** The grid Oskol asks for is
//// always 3-ply (`analysis.rolls_level`): at 4-ply the engine's per-roll rows
//// are corrupt -- nondeterministic between runs, biased low, and they flip
//// cube decisions -- and at 2-ply they are the bare network with no
//// lookahead. The engine refuses anything else, and so does this side. Only
//// the no-double rows are read: the double/take rows are on another scale
//// once the cube is owned or there is a match score (bg-roll-breakdown).
////
//// **The sign is the hazard.** A candidate play's grid is taken on the board
//// that play left, read from the **opponent's** side, so good for them is bad
//// for the player who moved. `opposite` turns a position round (the board,
//// the cube's owner and the away scores) and `diff` negates once more, so a
//// difference cell is positive where the second play does better for the
//// mover. Both are tested against positions whose answer is obvious; nothing
//// here may be changed without those tests.
////
//// The board's own turn-round is `oskol/puzzles.flip`, which the take page
//// already needed: one rule, one place.

import backgammon/analysis.{type Position, Position}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import oskol/puzzles

// ---------- The grid ----------

/// One board's grid as the engine sends it.
pub type Rolls {
  Rolls(
    /// The depth the per-roll rows came from, as the engine names it
    /// ("3ply"). Shown beside the grid, because the verdict above it is
    /// 4-ply and the two would otherwise read as disagreeing.
    level: String,
    /// The position's own equity: the weighted mean of the rows.
    equity: Float,
    rows: List(Roll),
  )
}

/// One of the 21 distinct rolls.
pub type Roll {
  Roll(
    /// Low die first, as the engine lists them.
    dice: #(Int, Int),
    /// How many of the 36 throws this row stands for: 1 for a double, 2
    /// otherwise.
    weight: Int,
    /// The roll's own cubeful equity, from the side the grid is drawn for.
    equity: Float,
    /// The engine's best play for this roll, in notation ("24/20(2) 13/9(2)").
    /// Empty where the roll plays nothing -- a dance, which is a cell worth
    /// drawing.
    best: String,
  )
}

/// A cell of the picture: a roll, and the number its colour comes from.
///
/// For a position's grid that number is the roll's own equity; for a
/// difference grid it is how much better the second play does on that roll.
/// Both are read by the same ramp, which is why they are one shape and one
/// field name.
pub type Cell {
  Cell(dice: #(Int, Int), weight: Int, value: Float, best: String)
}

/// How many of the 36 throws a roll stands for. A property of the dice, so it
/// is worked out here rather than taken on trust from the wire.
pub fn weight_of(dice: #(Int, Int)) -> Int {
  case dice.0 == dice.1 {
    True -> 1
    False -> 2
  }
}

/// All 36 throws.
pub const throws = 36

/// The rows' weighted mean, which is the position's own equity. Worked out
/// rather than taken from `equity` only where something has to check that the
/// two agree.
pub fn mean(rolls: Rolls) -> Float {
  weighted_mean(list.map(rolls.rows, fn(row) { #(row.weight, row.equity) }))
}

/// The 21 cells of one position's grid: its rows, under the field name both
/// kinds of grid use. The engine's own per-roll equities, carried through
/// rather than reworked -- a position's grid is the number it says it is.
pub fn cells(rolls: Rolls) -> List(Cell) {
  list.map(rolls.rows, fn(row) { cell(row.dice, row.equity, row.best) })
}

/// The difference grid of two plays, cell by cell: how much better (positive)
/// or worse (negative) `compared` does than `baseline` on each roll, for the
/// player who moved.
///
/// Both grids are taken on post-move boards and so read from the opponent's
/// side, which is the whole reason for the negation: a roll that leaves them
/// better off leaves the mover worse off. The cells' weighted mean is then the
/// plays' equity difference in the mover's view, which `rolls_test` holds.
///
/// `best` is the opponent's best reply after the second play -- what they
/// would do to you if you played it.
///
/// A roll the two grids do not share is left out; the engine answers all 21
/// or the answer is not a grid.
pub fn diff(baseline: Rolls, compared: Rolls) -> List(Cell) {
  list.filter_map(baseline.rows, fn(row) {
    use theirs <- result.map(row_of(compared, row.dice))
    cell(row.dice, float.negate(theirs.equity -. row.equity), theirs.best)
  })
}

fn cell(dice: #(Int, Int), value: Float, best: String) -> Cell {
  Cell(dice: dice, weight: weight_of(dice), value: value, best: best)
}

fn row_of(rolls: Rolls, dice: #(Int, Int)) -> Result(Roll, Nil) {
  list.find(rolls.rows, fn(row) { row.dice == dice })
}

/// The weighted mean of a list of cells: a position's grid averages to its own
/// equity, a difference grid to the plays' equity difference.
pub fn cells_mean(cells: List(Cell)) -> Float {
  weighted_mean(list.map(cells, fn(c) { #(c.weight, c.value) }))
}

/// One roll stands for one throw of the 36 or for two, so an average over
/// rolls is weighted. The divisor is the weight actually present rather than
/// 36, so a grid the engine answered short averages what it holds instead of
/// quietly reading low.
fn weighted_mean(pairs: List(#(Int, Float))) -> Float {
  let #(total, weight) =
    list.fold(pairs, #(0.0, 0), fn(so_far, pair) {
      let #(weight, value) = pair
      #(so_far.0 +. int.to_float(weight) *. value, so_far.1 + weight)
    })
  case weight {
    0 -> 0.0
    _ -> total /. int.to_float(weight)
  }
}

// ---------- Turning a position round ----------

/// The same position from the other side: the board turned round
/// (`puzzles.flip`), the cube's owner swapped and the away scores with it.
///
/// What a post-move board has to be read as, because the player on roll in it
/// is the opponent. Forgetting the away scores would give a match-score grid
/// for the wrong player, and forgetting the owner a cube that belongs to
/// nobody.
pub fn opposite(p: Position) -> Position {
  Position(
    ..p,
    board: puzzles.flip(p.board),
    cube_owner: case p.cube_owner {
      "player" -> "opponent"
      "opponent" -> "player"
      other -> other
    },
    away1: p.away2,
    away2: p.away1,
  )
}

// ---------- The wire ----------

/// `{level, equity, cells}`: what a turn of the replay's report carries and
/// what the grid endpoint answers. The rows go out as cells so that one
/// decoder and one ramp read a position's grid and a comparison alike.
pub fn to_json(rolls: Rolls) -> Json {
  grid_json(rolls.level, rolls.equity, cells(rolls))
}

/// A difference grid, in the same shape: its `equity` is the plays' equity
/// difference, which is the weighted mean of its cells.
pub fn diff_json(level: String, cells: List(Cell)) -> Json {
  grid_json(level, cells_mean(cells), cells)
}

fn grid_json(level: String, equity: Float, cells: List(Cell)) -> Json {
  json.object([
    #("level", json.string(level)),
    #("equity", json.float(equity)),
    #("cells", json.array(cells, cell_json)),
  ])
}

fn cell_json(c: Cell) -> Json {
  json.object([
    #("dice", json.array([c.dice.0, c.dice.1], json.int)),
    #("weight", json.int(c.weight)),
    #("value", json.float(c.value)),
    #("best", json.string(c.best)),
  ])
}

/// The engine's `rolls` object, wherever it appears: on a turn of a review
/// and as the whole answer of `POST /backgammon/rolls`.
pub fn decoder() -> Decoder(Rolls) {
  use level <- decode.field("level", decode.string)
  use equity <- decode.field("equity", number())
  use rows <- decode.field("rows", decode.list(row_decoder()))
  decode.success(Rolls(level: level, equity: equity, rows: rows))
}

fn row_decoder() -> Decoder(Roll) {
  use dice <- decode.field("dice", decode.list(decode.int))
  use equity <- decode.field("equity", number())
  use best <- decode.optional_field("best", "", decode.string)
  case dice {
    [a, b] ->
      decode.success(Roll(
        dice: #(a, b),
        weight: weight_of(#(a, b)),
        equity: equity,
        best: best,
      ))
    _ -> decode.failure(Roll(#(0, 0), 0, 0.0, ""), "Roll")
  }
}

/// Read one engine answer (`POST /backgammon/rolls`, or one result of a batch
/// of them).
pub fn parse(body: String) -> Result(Rolls, String) {
  json.parse(body, decoder())
  |> result.replace_error("The engine's grid did not read as a grid")
}

/// JSON numbers from Python may be written as 0 or 0.0.
fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}
