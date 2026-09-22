//// A puzzle's picture: the position drawn once as SVG, for the link
//// preview (`og:image`). Pure: a `Question` in, a string out, and the
//// Elixir side (`Oskol.Puzzles.Pictures`) rasterises it with rsvg-convert
//// in the review job and stores the PNG. Nothing here is read by the
//// page, which draws its own board in HTML; this is the same board in the
//// site's default colours, at the size every preview wants (1200 x 630).
////
//// The board is drawn from the **solver's** side, exactly as `prompt`
//// speaks: the mover is White at the bottom for a move or a double, and
//// for a take the doubled player is -- the stored board is turned around
//// (`puzzles.flip`), the cube's owner and the away scores with it. So the
//// picture and the sentence under it always agree about who White is.
////
//// Text is SVG text in a system font stack, never a web font: an image
//// loads nothing, and the runner image ships one sans (DejaVu) that the
//// stack ends on.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/puzzles.{type Question, Centered, Move, Mover, Opponent, Take}

// ---------- Colours ----------
//
// The site's default board, `.bg-theme-midnight` in assets/css/app.css
// (`oskol/guests/prefs.default_backgammon_theme`). A player's own theme
// never reaches a shared picture: a preview is for someone who has not
// picked one.

/// `--bg-frame`: the slab and the bar.
const frame = "#1d2230"

/// `--bg-slot`: the bear-off holders.
const slot = "#141823"

/// `--bg-felt`: the two halves.
const felt = "#3a4256"

/// `--bg-point-a` and `--bg-point-b`: the points, alternating.
const point_a = "#2c3547"

const point_b = "#59657f"

/// `--bg-checker-light` and `--bg-checker-light-ink` (`--ink`).
const light = "#ffffff"

const light_ink = "#23243a"

/// `--bg-checker-dark`, `--bg-checker-dark-ink` and `--bg-checker-edge`.
const dark = "#11131c"

const dark_ink = "#ffffff"

const edge = "#0d0f16"

/// The page's paper (`--paper`), for the words on the frame.
const paper = "#fbf9f3"

// ---------- Geometry ----------
//
// The og:image size, and the site's board inside it: a rounded slab, two
// felt halves recessed into it, the bar one unbroken column through the
// middle, six points a half, the centre band between the rows. Checkers
// are 84% of a point's width on the site; here the points are tall enough
// for five to overlap a little, as on a real board, rather than spill.

pub const width = 1200

pub const height = 630

const slab_x = 24

const slab_y = 24

const slab_w = 1152

const slab_h = 496

const frame_w = 12

const bar_w = 64

/// Each half is 532 wide: 2 of padding, six points of 88, 2 of padding.
const point_w = 88

const point_h = 196

const band_h = 80

const checker_r = 32

/// The distance between the centres of two checkers in a stack.
const stack_step = 33

const die_size = 56

const cube_size = 52

// Derived, spelled out so a reader can check them against the constants.
const inner_x = 36

const inner_y = 36

const left_x = 36

const right_x = 632

const top_row_y = 36

const band_y = 232

const bottom_row_y = 312

const inner_bottom = 508

const bar_centre = 600

// ---------- The picture ----------

/// The SVG of a question's board, or why there is none: a stored board
/// that is not the engine's 26 ints is not drawn as an empty one. What the
/// rasteriser is handed.
pub fn checked_svg(q: Question) -> Result(String, String) {
  case list.length(q.board) {
    26 -> Ok(svg(q))
    n -> Error("a stored board has " <> int.to_string(n) <> " entries, not 26")
  }
}

/// The SVG of a question's board, 1200 x 630. Total: any board draws
/// something, which is what a renderer wants; `checked_svg` is what a
/// store wants.
pub fn svg(q: Question) -> String {
  let view = solver_view(q)
  let caption = case view.away_mover == 0 && view.away_opponent == 0 {
    True ->
      case q.jacoby {
        True -> "Unlimited · Jacoby"
        False -> "Unlimited"
      }
    False ->
      "White "
      <> away(view.away_mover)
      <> " · Black "
      <> away(view.away_opponent)
      <> case q.crawford {
        True -> " · Crawford"
        False -> ""
      }
  }
  let dice = case q.kind, q.dice {
    Move, Some(#(high, low)) -> Some(#(high, low))
    _, _ -> None
  }
  document(
    view.board,
    dice,
    q.cube_value,
    view.cube_owner,
    caption,
    puzzles.prompt(q),
  )
}

/// The site's own picture, for a puzzle whose picture is not there (yet,
/// or ever): the opening position, nobody on roll, cube in the middle.
pub fn default_svg() -> String {
  document(
    opening,
    None,
    1,
    Centered,
    "Backgammon puzzles",
    "Did you get this? Play the position, then see the engine's answer.",
  )
}

/// The opening position in the engine's 26 ints: index 0 the opponent's
/// bar, 1..24 the points as White moves along them (24 -> 1), 25 White's
/// bar. White's 24-point is index 24.
const opening = [
  0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2,
  0,
]

type View {
  View(
    board: List(Int),
    cube_owner: puzzles.Owner,
    away_mover: Int,
    away_opponent: Int,
  )
}

/// The position as the solver sees it. Stored from the mover's side; a
/// take's solver is the other player, so their board is the stored one
/// turned around, with the cube's owner and the scores read from their
/// side too.
fn solver_view(q: Question) -> View {
  case q.kind {
    Take ->
      View(
        board: puzzles.flip(q.board),
        cube_owner: case q.cube_owner {
          Mover -> Opponent
          Opponent -> Mover
          Centered -> Centered
        },
        away_mover: q.away_opponent,
        away_opponent: q.away_mover,
      )
    _ -> View(q.board, q.cube_owner, q.away_mover, q.away_opponent)
  }
}

fn away(n: Int) -> String {
  int.to_string(n) <> " away"
}

fn document(
  board: List(Int),
  dice: option.Option(#(Int, Int)),
  cube_value: Int,
  cube_owner: puzzles.Owner,
  caption: String,
  prompt: String,
) -> String {
  let position = read(board)
  string.concat([
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\""
      <> int.to_string(width)
      <> "\" height=\""
      <> int.to_string(height)
      <> "\" viewBox=\"0 0 "
      <> int.to_string(width)
      <> " "
      <> int.to_string(height)
      <> "\">",
    // The page behind the slab: the same frame colour, so the picture is
    // one dark card whatever a preview crops.
    rect(0, 0, width, height, frame, 0),
    slab(),
    halves(),
    points(position),
    bar(position),
    trays(position),
    cube(cube_value, cube_owner),
    case dice {
      Some(#(high, low)) -> dice_pair(high, low)
      None -> ""
    },
    words(caption, prompt),
    "</svg>",
  ])
}

// ---------- Reading the board ----------

/// A point's stack: how many, and whose (True for the solver's, White).
type Stack {
  Stack(count: Int, white: Bool)
}

type Position {
  Position(
    /// Points 1..24, in that order.
    points: List(Stack),
    white_bar: Int,
    black_bar: Int,
    white_off: Int,
    black_off: Int,
  )
}

fn read(board: List(Int)) -> Position {
  let black_bar = list.first(board) |> option.from_result |> option.unwrap(0)
  let rest = list.drop(board, 1)
  let point_counts = list.take(rest, 24)
  let white_bar =
    list.drop(rest, 24)
    |> list.first
    |> option.from_result
    |> option.unwrap(0)
  let points =
    list.map(point_counts, fn(n) {
      case n >= 0 {
        True -> Stack(n, True)
        False -> Stack(-n, False)
      }
    })
  let white_on =
    list.fold(points, 0, fn(sum, s) {
      case s.white {
        True -> sum + s.count
        False -> sum
      }
    })
  let black_on =
    list.fold(points, 0, fn(sum, s) {
      case s.white {
        True -> sum
        False -> sum + s.count
      }
    })
  Position(
    points: points,
    white_bar: white_bar,
    black_bar: black_bar,
    white_off: int.max(0, 15 - white_on - white_bar),
    black_off: int.max(0, 15 - black_on - black_bar),
  )
}

fn stack_at(position: Position, point: Int) -> Stack {
  list.drop(position.points, point - 1)
  |> list.first
  |> option.from_result
  |> option.unwrap(Stack(0, True))
}

// ---------- The slab, the halves, the points ----------

fn slab() -> String {
  rect(slab_x, slab_y, slab_w, slab_h, frame, 14)
}

fn halves() -> String {
  let h = slab_h - 2 * frame_w
  let w = right_x - left_x - bar_w
  rect(left_x, inner_y, w, h, felt, 6) <> rect(right_x, inner_y, w, h, felt, 6)
}

/// The rows as the solver sees them: their home board bottom right, so the
/// bottom row runs 12 .. 1 left to right and the top row 13 .. 24.
fn points(position: Position) -> String {
  let top = list.range(13, 24)
  let bottom = list.range(12, 1)
  string.concat([
    row(position, list.take(top, 6), left_x + 2, True),
    row(position, list.drop(top, 6), right_x + 2, True),
    row(position, list.take(bottom, 6), left_x + 2, False),
    row(position, list.drop(bottom, 6), right_x + 2, False),
  ])
}

fn row(position: Position, numbers: List(Int), x0: Int, top: Bool) -> String {
  numbers
  |> list.index_map(fn(number, index) {
    let x = x0 + index * point_w
    let colour = case index % 2 == 0 {
      True -> point_a
      False -> point_b
    }
    triangle(x, top, colour)
    <> stack(stack_at(position, number), x, top, int.to_string(number))
  })
  |> string.concat
}

/// A point: a triangle the width of its slot, its apex 92% of the way
/// down (or up), as the site clips it.
fn triangle(x: Int, top: Bool, colour: String) -> String {
  let apex_x = x + point_w / 2
  let points = case top {
    True ->
      coords(x, top_row_y)
      <> " "
      <> coords(x + point_w, top_row_y)
      <> " "
      <> coords(apex_x, top_row_y + point_h * 92 / 100)
    False ->
      coords(x, inner_bottom)
      <> " "
      <> coords(x + point_w, inner_bottom)
      <> " "
      <> coords(apex_x, inner_bottom - point_h * 92 / 100)
  }
  "<polygon points=\"" <> points <> "\" fill=\"" <> colour <> "\"/>"
}

/// Up to five checkers, the fifth carrying the whole count when there are
/// more (`View.elm`'s `viewStack`).
fn stack(s: Stack, x: Int, top: Bool, place: String) -> String {
  let cx = x + point_w / 2
  let first = case top {
    True -> top_row_y + checker_r
    False -> inner_bottom - checker_r
  }
  let step = case top {
    True -> stack_step
    False -> -stack_step
  }
  column(s, cx, first, step, place)
}

fn column(s: Stack, cx: Int, first: Int, step: Int, place: String) -> String {
  let shown = int.min(s.count, 5)
  case shown {
    0 -> ""
    _ ->
      list.range(0, shown - 1)
      |> list.map(fn(i) {
        let cy = first + i * step
        let count = case i == shown - 1 && s.count > 5 {
          True -> Some(s.count)
          False -> None
        }
        checker(cx, cy, s.white, count, place)
      })
      |> string.concat
  }
}

fn checker(
  cx: Int,
  cy: Int,
  white: Bool,
  count: option.Option(Int),
  place: String,
) -> String {
  let #(fill, ink, name) = case white {
    True -> #(light, light_ink, "white")
    False -> #(dark, dark_ink, "black")
  }
  let disc =
    "<circle class=\"checker "
    <> name
    <> "\" data-place=\""
    <> place
    <> "\" cx=\""
    <> int.to_string(cx)
    <> "\" cy=\""
    <> int.to_string(cy)
    <> "\" r=\""
    <> int.to_string(checker_r)
    <> "\" fill=\""
    <> fill
    <> "\" stroke=\""
    <> edge
    <> "\" stroke-width=\"2\"/>"
  // A dark checker on the dark point gets the faint inner ring the site's
  // swatch has, so its edge reads.
  let ring = case white {
    True -> ""
    False ->
      "<circle cx=\""
      <> int.to_string(cx)
      <> "\" cy=\""
      <> int.to_string(cy)
      <> "\" r=\""
      <> int.to_string(checker_r - 3)
      <> "\" fill=\"none\" stroke=\"rgba(255,255,255,0.28)\" stroke-width=\"2\"/>"
  }
  let label = case count {
    Some(n) ->
      "<text class=\"count\" data-place=\""
      <> place
      <> "\" x=\""
      <> int.to_string(cx)
      <> "\" y=\""
      <> int.to_string(cy)
      <> "\" fill=\""
      <> ink
      <> "\" font-size=\"26\" font-weight=\"700\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\""
      <> font
      <> "\">"
      <> int.to_string(n)
      <> "</text>"
    None -> ""
  }
  disc <> ring <> label
}

// ---------- The bar, the trays, the cube, the dice ----------

/// Checkers on the bar: the opponent's hang from the top, the solver's
/// stand on the bottom, each the size of one on a point.
fn bar(position: Position) -> String {
  column(
    Stack(position.black_bar, False),
    bar_centre,
    top_row_y + checker_r,
    stack_step,
    "bar",
  )
  <> column(
    Stack(position.white_bar, True),
    bar_centre,
    inner_bottom - checker_r,
    -stack_step,
    "bar",
  )
}

/// The bear-off trays, in the left half's band: three holders of five each
/// side, the checkers borne off stacked edge-on, the opponent's row above
/// the solver's. Drawn as the site's identity bars draw them.
fn trays(position: Position) -> String {
  tray(position.black_off, band_y + 8, False)
  <> tray(position.white_off, band_y + band_h - 8 - 20, True)
}

const stick_w = 6

const stick_gap = 3

const holder_pad = 3

const holder_h = 20

fn tray(off: Int, y: Int, white: Bool) -> String {
  let holder_w = 5 * stick_w + 4 * stick_gap + 2 * holder_pad
  let x0 = left_x + 12
  let name = case white {
    True -> "white"
    False -> "black"
  }
  let fill = case white {
    True -> light
    False -> dark
  }
  let holders =
    list.range(0, 2)
    |> list.map(fn(h) {
      let x = x0 + h * { holder_w + 6 }
      let in_holder = int.clamp(off - h * 5, 0, 5)
      let sticks = case in_holder {
        0 -> ""
        _ ->
          list.range(0, in_holder - 1)
          |> list.map(fn(i) {
            let sx = x + holder_pad + i * { stick_w + stick_gap }
            "<rect class=\"off-stick "
            <> name
            <> "\" x=\""
            <> int.to_string(sx)
            <> "\" y=\""
            <> int.to_string(y + holder_pad)
            <> "\" width=\""
            <> int.to_string(stick_w)
            <> "\" height=\""
            <> int.to_string(holder_h - 2 * holder_pad)
            <> "\" rx=\"1\" fill=\""
            <> fill
            <> "\"/>"
          })
          |> string.concat
      }
      rect(x, y, holder_w, holder_h, slot, 3) <> sticks
    })
    |> string.concat
  let label = case off {
    0 -> ""
    n ->
      "<text class=\"off-count "
      <> name
      <> "\" x=\""
      <> int.to_string(x0 + 3 * holder_w + 2 * 6 + 8)
      <> "\" y=\""
      <> int.to_string(y + holder_h / 2)
      <> "\" fill=\""
      <> paper
      <> "\" fill-opacity=\"0.8\" font-size=\"16\" dominant-baseline=\"central\" font-family=\""
      <> font
      <> "\">"
      <> int.to_string(n)
      <> " off</text>"
  }
  holders <> label
}

/// The cube hangs on the bar: in the middle while it is centred, at the
/// band end of its owner's row once it has been turned.
fn cube(value: Int, owner: puzzles.Owner) -> String {
  let cy = case owner {
    Centered -> band_y + band_h / 2
    Mover -> bottom_row_y + cube_size / 2 + 6
    Opponent -> band_y - cube_size / 2 - 6
  }
  let x = bar_centre - cube_size / 2
  let y = cy - cube_size / 2
  "<rect class=\"cube\" data-owner=\""
  <> puzzles.owner_name(owner)
  <> "\" x=\""
  <> int.to_string(x)
  <> "\" y=\""
  <> int.to_string(y + 3)
  <> "\" width=\""
  <> int.to_string(cube_size)
  <> "\" height=\""
  <> int.to_string(cube_size)
  <> "\" rx=\"6\" fill=\"rgba(0,0,0,0.45)\"/>"
  <> "<rect x=\""
  <> int.to_string(x)
  <> "\" y=\""
  <> int.to_string(y)
  <> "\" width=\""
  <> int.to_string(cube_size)
  <> "\" height=\""
  <> int.to_string(cube_size)
  <> "\" rx=\"6\" fill=\""
  <> light
  <> "\"/>"
  <> "<text class=\"cube-value\" x=\""
  <> int.to_string(bar_centre)
  <> "\" y=\""
  <> int.to_string(cy)
  <> "\" fill=\""
  <> light_ink
  <> "\" font-size=\"24\" font-weight=\"700\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\""
  <> font
  <> "\">"
  <> int.to_string(value)
  <> "</text>"
}

/// The roll, in the right half's band as the site keeps it: two white dice
/// with the hard drop of the site's, pips in ink.
fn dice_pair(high: Int, low: Int) -> String {
  let centre = right_x + { right_x - left_x - bar_w } / 2
  let cy = band_y + band_h / 2
  die(centre - die_size / 2 - 8, cy, high)
  <> die(centre + die_size / 2 + 8, cy, low)
}

fn die(cx: Int, cy: Int, value: Int) -> String {
  let x = cx - die_size / 2
  let y = cy - die_size / 2
  let shadow = rect(x + 3, y + 3, die_size, die_size, edge, 8)
  let face =
    "<rect class=\"die\" data-value=\""
    <> int.to_string(value)
    <> "\" x=\""
    <> int.to_string(x)
    <> "\" y=\""
    <> int.to_string(y)
    <> "\" width=\""
    <> int.to_string(die_size)
    <> "\" height=\""
    <> int.to_string(die_size)
    <> "\" rx=\"8\" fill=\""
    <> light
    <> "\" stroke=\""
    <> edge
    <> "\" stroke-width=\"2\"/>"
  let pips =
    pips_on(value)
    |> list.map(fn(offset) {
      let #(dx, dy) = offset
      "<circle class=\"pip\" cx=\""
      <> int.to_string(cx + dx * 15)
      <> "\" cy=\""
      <> int.to_string(cy + dy * 15)
      <> "\" r=\"5\" fill=\""
      <> light_ink
      <> "\"/>"
    })
    |> string.concat
  shadow <> face <> pips
}

/// Where a face's pips sit, on a -1 .. 1 grid.
fn pips_on(value: Int) -> List(#(Int, Int)) {
  case value {
    1 -> [#(0, 0)]
    2 -> [#(-1, -1), #(1, 1)]
    3 -> [#(-1, -1), #(0, 0), #(1, 1)]
    4 -> [#(-1, -1), #(1, -1), #(-1, 1), #(1, 1)]
    5 -> [#(-1, -1), #(1, -1), #(0, 0), #(-1, 1), #(1, 1)]
    6 -> [#(-1, -1), #(1, -1), #(-1, 0), #(1, 0), #(-1, 1), #(1, 1)]
    _ -> []
  }
}

// ---------- The words ----------

/// No web font in an image: the system's sans, ending on the one the
/// runner image ships (DejaVu).
const font = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, 'DejaVu Sans', sans-serif"

fn words(caption: String, prompt: String) -> String {
  let left = int.to_string(inner_x)
  "<text class=\"prompt\" x=\""
  <> left
  <> "\" y=\"570\" fill=\""
  <> paper
  <> "\" font-size=\"36\" font-weight=\"600\" font-family=\""
  <> font
  <> "\">"
  <> escape(prompt)
  <> "</text>"
  <> "<text class=\"score\" x=\""
  <> left
  <> "\" y=\"610\" fill=\""
  <> paper
  <> "\" fill-opacity=\"0.75\" font-size=\"22\" font-family=\""
  <> font
  <> "\">"
  <> escape(caption)
  <> "</text>"
  <> "<text class=\"site\" x=\""
  <> int.to_string(slab_x + slab_w)
  <> "\" y=\"610\" fill=\""
  <> paper
  <> "\" fill-opacity=\"0.75\" font-size=\"22\" text-anchor=\"end\" font-family=\""
  <> font
  <> "\">oskol.io</text>"
}

// ---------- Primitives ----------

fn rect(x: Int, y: Int, w: Int, h: Int, fill: String, radius: Int) -> String {
  "<rect x=\""
  <> int.to_string(x)
  <> "\" y=\""
  <> int.to_string(y)
  <> "\" width=\""
  <> int.to_string(w)
  <> "\" height=\""
  <> int.to_string(h)
  <> "\" rx=\""
  <> int.to_string(radius)
  <> "\" fill=\""
  <> fill
  <> "\"/>"
}

fn coords(x: Int, y: Int) -> String {
  int.to_string(x) <> "," <> int.to_string(y)
}

/// The five characters XML text cannot carry as they are.
pub fn escape(text: String) -> String {
  text
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}
