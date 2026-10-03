//// The per-roll grid: the weights, what a cell is, and the sign.
////
//// The grids here are the engine's own answers, taken from the live service
//// (`oskol/puzzles/fixture.rolls_sample`), so the invariant everything leans
//// on -- the rows' weighted mean is the headline equity -- is held against
//// real numbers rather than against numbers chosen to hold it.
////
//// **The sign is the hazard** (bg-roll-breakdown): a candidate's grid is read
//// from the opponent's side and a difference negates it once more, so a double
//// inversion looks entirely plausible. Every test of it below is on a position
//// whose answer needs no engine to check: 6-6 is the best opening roll there
//// is, and a play that leaves the opponent on the bar with blots to shoot at
//// is worse on exactly the rolls that let them hit.
////
//// There is nothing here about bands or colours. A cell is the roll's own
//// equity and the page draws one fixed ramp over it (0 neutral, +-1 the ends,
//// `docs/api.md`), so the only thing to hold is that the number is the number.

import backgammon/analysis.{Position}
import backgammon/board.{type Board, Black, White}
import gleam/dynamic/decode
import gleam/float
import gleam/json
import gleam/list
import gleam/string
import oskol/analysis/rolls.{type Cell, type Rolls, Roll, Rolls}
import oskol/puzzles
import oskol/puzzles/fixture
import oskol/puzzles/tree

fn opening() -> Rolls {
  fixture.rolls_sample("opening")
}

fn cell_of(cells: List(Cell), dice: #(Int, Int)) -> Cell {
  let assert Ok(cell) = list.find(cells, fn(c) { c.dice == dice })
  cell
}

const tiny = 0.0000001

// ---------- The grid ----------

pub fn a_grid_is_twenty_one_rolls_standing_for_thirty_six_test() {
  let cells = rolls.cells(opening())
  assert list.length(cells) == 21
  assert list.fold(cells, 0, fn(total, c) { total + c.weight }) == rolls.throws
  // A double is one throw of the 36 and anything else is two.
  assert cell_of(cells, #(4, 4)).weight == 1
  assert cell_of(cells, #(2, 6)).weight == 2
}

/// A cell is the roll's own equity, carried through and not reworked: zero is
/// an even position, so one fixed ramp reads every grid the same way. (It was
/// the roll's equity minus the position's own -- luck -- until 2026-10-02.)
pub fn a_cell_is_the_rolls_own_equity_test() {
  let grid = opening()
  let cells = rolls.cells(grid)
  list.each(grid.rows, fn(row) {
    let cell = cell_of(cells, row.dice)
    assert cell.value == row.equity
    assert cell.best == row.best
    assert cell.weight == row.weight
  })
  // And so the cells average to the headline, not to zero.
  assert float.loosely_equals(rolls.cells_mean(cells), grid.equity, tiny)
}

/// The whole page leans on this: the headline above the grid is the average of
/// the cells beneath it, so the two can never read as disagreeing. Held to
/// 1e-7 over the engine's own numbers (its own worst disagreement over twenty
/// live grids was 7.8e-08).
pub fn the_rows_weighted_mean_is_the_headline_test() {
  list.each(["opening", "baseline", "compared"], fn(name) {
    let grid = fixture.rolls_sample(name)
    assert float.loosely_equals(rolls.mean(grid), grid.equity, tiny)
    let cells = rolls.cells(grid)
    assert float.loosely_equals(rolls.cells_mean(cells), grid.equity, tiny)
  })
}

// ---------- The sign, where the answer is obvious ----------

/// 6-6 is the best opening roll in backgammon. A grid of the mover's own rolls
/// has to say so, or the colours are the wrong way round.
pub fn the_opening_grids_best_roll_is_double_six_test() {
  let cells = rolls.cells(opening())
  let best = cell_of(cells, #(6, 6))
  // Nothing beats it: the best of the 21, and by a long way.
  assert best.value >. 0.0
  assert list.all(cells, fn(c) { c.value <=. best.value })
  assert best.value >. 0.5
  assert best.best == "24/18(2) 13/7(2)"
  // The awkward small rolls are the ones that leave White no better than even:
  // 1-2 and 1-4 are the only two the engine reads as slightly negative there,
  // and the worst of the 21 is not a double.
  assert cell_of(cells, #(1, 2)).value <. 0.0
  assert cell_of(cells, #(1, 4)).value <. 0.0
  let assert Ok(worst) =
    list.sort(cells, fn(a, b) { float.compare(a.value, b.value) })
    |> list.first
  assert worst.dice.0 != worst.dice.1
}

/// The real pair: the board 24/18 13/8 leaves against the board a blot-leaving
/// play of 6-5 leaves, both read from the opponent's side.
///
/// The second play puts a checker on their bar and leaves blots, so the rolls
/// that enter and hit are the ones it loses to, and the rolls it survives are
/// the ones they cannot play at all. A difference cell is positive where the
/// second play does better for the player who moved, so a dance is positive
/// and a hit is negative. Get the sign wrong and this test says the opposite.
pub fn a_difference_grid_is_positive_where_the_second_play_does_better_test() {
  let baseline = fixture.rolls_sample("baseline")
  let compared = fixture.rolls_sample("compared")
  let cells = rolls.diff(baseline, compared)
  assert list.length(cells) == 21

  // They dance on these, which is the best thing that can happen to us.
  list.each([#(5, 5), #(6, 6), #(5, 6)], fn(dice) {
    let cell = cell_of(cells, dice)
    assert cell.value >. 0.0
    assert cell.best == ""
  })
  // And they come in hitting on these, which is the worst: half the cube or
  // more, each way, on a scale where 1 is the whole of it.
  list.each([#(2, 2), #(2, 6), #(1, 1), #(2, 3)], fn(dice) {
    let cell = cell_of(cells, dice)
    assert cell.value <. -0.5
  })
  // The play is worse overall, and by exactly the equity between them.
  assert float.loosely_equals(
    rolls.cells_mean(cells),
    float.negate(compared.equity -. baseline.equity),
    tiny,
  )
  assert rolls.cells_mean(cells) <. 0.0
}

/// The same rule on numbers nobody has to trust an engine for: two grids that
/// agree everywhere except 6-6, where the second play leaves the opponent
/// less. That is better for the mover, so 6-6 is positive there.
pub fn a_play_that_leaves_them_less_on_double_six_is_positive_there_test() {
  let baseline = flat_grid(0.1)
  let compared =
    Rolls(..baseline, rows: [
      Roll(#(6, 6), 1, -0.4, "bar/20 13/7"),
      ..list.filter(baseline.rows, fn(r) { r.dice != #(6, 6) })
    ])
  let cells = rolls.diff(baseline, compared)
  let six = cell_of(cells, #(6, 6))
  assert six.value >. 0.0
  assert float.loosely_equals(six.value, 0.5, tiny)
  // Every other roll is the same on both, so every other cell is zero.
  assert list.all(list.filter(cells, fn(c) { c.dice != #(6, 6) }), fn(c) {
    float.loosely_equals(c.value, 0.0, tiny)
  })
  // And the whole difference is that one roll's, weighted as one throw of 36.
  assert float.loosely_equals(rolls.cells_mean(cells), 0.5 /. 36.0, tiny)
}

/// Every roll at the same equity, so one roll's difference stands on its own.
fn flat_grid(equity: Float) -> Rolls {
  Rolls(
    level: analysis.rolls_level,
    equity: equity,
    rows: list.map(dice_pairs(), fn(dice) {
      Roll(dice, rolls.weight_of(dice), equity, "13/7")
    }),
  )
}

/// The 21 distinct rolls, doubles first, as the engine lists them.
fn dice_pairs() -> List(#(Int, Int)) {
  let doubles = list.range(1, 6) |> list.map(fn(d) { #(d, d) })
  let rest =
    list.range(1, 5)
    |> list.flat_map(fn(low) {
      list.range(low + 1, 6) |> list.map(fn(high) { #(low, high) })
    })
  list.append(doubles, rest)
}

// ---------- Turning a board round ----------

/// A position with a checker on each bar and a blot either side, so every part
/// of the 26 ints is in play -- the bars especially, which are plain counts
/// where the points are signed.
fn contact_board() -> Board {
  let assert Ok(b) =
    tree.from_engine([
      1, 1, 0, 0, 0, 2, 3, 0, 1, 0, 0, 0, -6, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0,
      2, 1,
    ])
  b
}

pub fn turning_a_board_round_is_its_own_inverse_test() {
  let mover = analysis.encode(contact_board(), White)
  // Both bars hold a checker, and they are not the same slot.
  assert list.first(mover) == Ok(1)
  assert list.last(mover) == Ok(1)
  assert puzzles.flip(puzzles.flip(mover)) == mover
}

/// The stronger statement, and the one the sign depends on: turning the
/// engine's board round is the same thing as encoding the position from the
/// other player's side. Were it not, a candidate's grid would be of a position
/// nobody is in.
pub fn turning_a_board_round_is_the_other_sides_encoding_test() {
  let b = contact_board()
  assert puzzles.flip(analysis.encode(b, White)) == analysis.encode(b, Black)
  assert puzzles.flip(analysis.encode(b, Black)) == analysis.encode(b, White)
}

pub fn the_other_side_swaps_the_cube_and_the_score_test() {
  let p =
    Position(
      board: analysis.encode(contact_board(), White),
      cube_value: 2,
      cube_owner: "player",
      away1: 3,
      away2: 5,
      crawford: False,
    )
  let other = rolls.opposite(p)
  assert other.cube_owner == "opponent"
  assert other.away1 == 5
  assert other.away2 == 3
  assert other.cube_value == 2
  assert other.board == analysis.encode(contact_board(), Black)
  // Twice round is where it started.
  assert rolls.opposite(other) == p
  // A centred cube belongs to nobody from either side.
  let centred = Position(..p, cube_owner: "centered")
  assert rolls.opposite(centred).cube_owner == "centered"
}

// ---------- The wire ----------

/// A page is sent cells: the dice, the weight behind them, the number its
/// colour comes from, and what the engine would play. No band and no colour --
/// the ramp is fixed and absolute, so there is nothing for the server to say
/// about it (`docs/api.md`).
pub fn a_grid_goes_out_as_cells_test() {
  let cell_decoder = {
    use dice <- decode.field("dice", decode.list(decode.int))
    use weight <- decode.field("weight", decode.int)
    use value <- decode.field("value", decode.float)
    use best <- decode.field("best", decode.string)
    decode.success(#(dice, weight, value, best))
  }
  let reader = {
    use level <- decode.field("level", decode.string)
    use equity <- decode.field("equity", decode.float)
    use cells <- decode.field("cells", decode.list(cell_decoder))
    decode.success(#(level, equity, cells))
  }
  let text = json.to_string(rolls.to_json(opening()))
  let assert Ok(#(level, equity, cells)) = json.parse(text, reader)
  assert level == analysis.rolls_level
  assert float.loosely_equals(equity, opening().equity, tiny)
  assert list.length(cells) == 21
  let assert Ok(#(dice, weight, value, best)) = list.first(cells)
  let first = cell_of(rolls.cells(opening()), #(1, 1))
  assert dice == [1, 1]
  assert weight == 1
  assert float.loosely_equals(value, first.value, tiny)
  assert best == first.best
  // Nothing about colour on the wire, and the rows never leave as rows.
  assert !string.contains(text, "band")
  assert !string.contains(text, "rows")
}

/// A difference grid goes out in the same shape, and its own equity is the
/// plays' equity difference -- the weighted mean of its cells.
pub fn a_difference_grid_says_what_it_averages_to_test() {
  let baseline = fixture.rolls_sample("baseline")
  let compared = fixture.rolls_sample("compared")
  let cells = rolls.diff(baseline, compared)
  let reader = {
    use level <- decode.field("level", decode.string)
    use equity <- decode.field("equity", decode.float)
    decode.success(#(level, equity))
  }
  let assert Ok(#(level, equity)) =
    json.parse(json.to_string(rolls.diff_json(compared.level, cells)), reader)
  assert level == analysis.rolls_level
  assert float.loosely_equals(equity, rolls.cells_mean(cells), tiny)
}
