//// The picture a puzzle is shared with: controlled questions in, and the
//// structure of the SVG out -- how many checkers each point carries and
//// whose, the count a tall stack shows, the dice, the cube at its owner's
//// side, the score line. Never the bytes: a change of colour or of a
//// coordinate is not a change of what the picture says.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import oskol/puzzles.{
  type Question, Centered, Double, Move, Mover, Opponent, Question, Take,
}
import oskol/puzzles/picture

// ---------- Boards ----------

/// The engine's 26 ints from the mover's side: index 0 the opponent's bar,
/// 1..24 the points (the mover moves 24 -> 1), 25 the mover's bar.
fn board_with(entries: List(#(Int, Int))) -> List(Int) {
  list.range(0, 25)
  |> list.map(fn(index) {
    list.find(entries, fn(e) { e.0 == index })
    |> option.from_result
    |> option.map(fn(e) { e.1 })
    |> option.unwrap(0)
  })
}

/// A middle-game position: the mover has a checker on the bar and two
/// borne off, the opponent one on the bar and a seven-stack.
fn a_board() -> List(Int) {
  board_with([
    #(25, 1),
    #(24, 2),
    #(13, 4),
    #(8, 3),
    #(6, 3),
    #(0, 1),
    #(1, -2),
    #(12, -7),
    #(17, -3),
    #(19, -2),
  ])
}

fn a_question(kind: puzzles.Kind) -> Question {
  Question(
    kind: kind,
    board: a_board(),
    dice: case kind {
      Move -> Some(#(6, 4))
      _ -> None
    },
    cube_value: 2,
    cube_owner: Mover,
    away_mover: 3,
    away_opponent: 5,
    crawford: False,
    jacoby: False,
  )
}

// ---------- Reading the SVG ----------

fn count(svg: String, needle: String) -> Int {
  list.length(string.split(svg, needle)) - 1
}

fn checkers(svg: String, colour: String, place: String) -> Int {
  count(
    svg,
    "class=\"checker " <> colour <> "\" data-place=\"" <> place <> "\"",
  )
}

fn attribute(svg: String, class: String) -> String {
  case string.split(svg, "class=\"" <> class <> "\"") {
    [_, rest, ..] ->
      case string.split(rest, "</text>") {
        [element, ..] ->
          case string.split(element, ">") {
            [_, text, ..] -> text
            _ -> ""
          }
        _ -> ""
      }
    _ -> ""
  }
}

// ---------- The board ----------

pub fn a_move_question_draws_every_checker_where_it_stands_test() {
  let svg = picture.svg(a_question(Move))

  assert string.starts_with(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\"")
  assert string.contains(svg, "viewBox=\"0 0 1200 630\"")

  // The mover is White: their stacks by point, five drawn at most.
  assert checkers(svg, "white", "24") == 2
  assert checkers(svg, "white", "13") == 4
  assert checkers(svg, "white", "8") == 3
  assert checkers(svg, "white", "6") == 3
  assert checkers(svg, "white", "bar") == 1
  // The opponent is Black. Seven on the 12-point draws five, the top one
  // carrying the count.
  assert checkers(svg, "black", "1") == 2
  assert checkers(svg, "black", "12") == 5
  assert attribute(svg, "count\" data-place=\"12") == "7"
  assert checkers(svg, "black", "17") == 3
  assert checkers(svg, "black", "19") == 2
  assert checkers(svg, "black", "bar") == 1
  // Nothing on an empty point, and no count on a short stack.
  assert checkers(svg, "white", "5") == 0
  assert checkers(svg, "black", "5") == 0
  assert count(svg, "class=\"count\"") == 1
  // Every checker is drawn or counted: the mover's 13 on the board and 2
  // in the tray; the opponent's 15 on the board, two of them only as the
  // seven-stack's count.
  assert count(svg, "class=\"checker white\"") == 13
  assert count(svg, "class=\"checker black\"") == 13
  assert count(svg, "class=\"off-stick white\"") == 2
  assert count(svg, "class=\"off-stick black\"") == 0
  assert attribute(svg, "off-count white") == "2 off"
}

pub fn a_move_question_shows_its_dice_and_the_cube_at_its_owner_test() {
  let svg = picture.svg(a_question(Move))

  assert count(svg, "class=\"die\"") == 2
  assert string.contains(svg, "class=\"die\" data-value=\"6\"")
  assert string.contains(svg, "class=\"die\" data-value=\"4\"")
  // Six pips and four: ten on the two faces.
  assert count(svg, "class=\"pip\"") == 10

  assert string.contains(svg, "class=\"cube\" data-owner=\"mover\"")
  assert attribute(svg, "cube-value") == "2"
}

pub fn doubles_draw_two_faces_of_the_same_die_test() {
  let q = Question(..a_question(Move), dice: Some(#(3, 3)))
  let svg = picture.svg(q)

  assert count(svg, "class=\"die\" data-value=\"3\"") == 2
  assert count(svg, "class=\"pip\"") == 6
  assert attribute(svg, "prompt") == "White to play 3-3. What&apos;s your play?"
}

// ---------- The cube questions ----------

pub fn a_double_question_has_no_dice_and_a_centred_cube_in_the_middle_test() {
  let q = Question(..a_question(Double), cube_value: 1, cube_owner: Centered)
  let svg = picture.svg(q)

  assert count(svg, "class=\"die\"") == 0
  assert count(svg, "class=\"pip\"") == 0
  assert string.contains(svg, "class=\"cube\" data-owner=\"center\"")
  assert attribute(svg, "cube-value") == "1"
  assert attribute(svg, "prompt") == "White to play. Double?"
  // The board itself is the mover's, as for a move.
  assert checkers(svg, "white", "24") == 2
  assert checkers(svg, "black", "12") == 5
}

pub fn a_take_is_drawn_from_the_doubled_players_side_test() {
  let q = Question(..a_question(Take), cube_owner: Centered)
  let svg = picture.svg(q)

  assert attribute(svg, "prompt") == "White is doubled. Take?"
  // The stored board is the doubler's; the solver is the other player, so
  // White is now what was Black, turned around: the seven-stack that was
  // the opponent's on their 12-point is White's on the 13-point.
  assert checkers(svg, "white", "13") == 5
  assert attribute(svg, "count\" data-place=\"13") == "7"
  assert checkers(svg, "white", "24") == 2
  assert checkers(svg, "black", "1") == 2
  assert checkers(svg, "black", "12") == 4
  assert checkers(svg, "white", "bar") == 1
  assert checkers(svg, "black", "bar") == 1
  // The two borne off were the doubler's, so they are Black's now.
  assert count(svg, "class=\"off-stick black\"") == 2
  assert count(svg, "class=\"off-stick white\"") == 0
  // And the scores swap with the board.
  assert attribute(svg, "score") == "White 5 away · Black 3 away"
  assert string.contains(svg, "class=\"cube\" data-owner=\"center\"")
}

pub fn a_take_turns_an_owned_cube_around_too_test() {
  let owned_by_doubler = Question(..a_question(Take), cube_owner: Mover)
  assert string.contains(
    picture.svg(owned_by_doubler),
    "class=\"cube\" data-owner=\"opponent\"",
  )

  let owned_by_solver = Question(..a_question(Take), cube_owner: Opponent)
  assert string.contains(
    picture.svg(owned_by_solver),
    "class=\"cube\" data-owner=\"mover\"",
  )
}

pub fn an_opponents_cube_sits_at_their_side_test() {
  let q = Question(..a_question(Move), cube_owner: Opponent, cube_value: 4)
  let svg = picture.svg(q)
  assert string.contains(svg, "class=\"cube\" data-owner=\"opponent\"")
  assert attribute(svg, "cube-value") == "4"
}

// ---------- The score line ----------

pub fn match_play_says_how_far_each_side_is_and_marks_crawford_test() {
  assert attribute(picture.svg(a_question(Move)), "score")
    == "White 3 away · Black 5 away"

  let crawford = Question(..a_question(Move), away_opponent: 1, crawford: True)
  assert attribute(picture.svg(crawford), "score")
    == "White 3 away · Black 1 away · Crawford"
}

pub fn money_play_says_unlimited_and_marks_jacoby_test() {
  let money = Question(..a_question(Move), away_mover: 0, away_opponent: 0)
  assert attribute(picture.svg(money), "score") == "Unlimited"
  let single = Question(..money, away_mover: 1, away_opponent: 1)
  assert attribute(picture.svg(single), "score") == "Single game"
  assert attribute(picture.svg(Question(..single, crawford: True)), "score")
    == "White 1 away · Black 1 away · Crawford"

  let jacoby = Question(..money, jacoby: True)
  assert attribute(picture.svg(jacoby), "score") == "Unlimited · Jacoby"
}

// ---------- Text safety ----------

pub fn the_words_are_xml_text_test() {
  // The prompt carries an apostrophe; nothing an SVG parser would trip on
  // reaches the text as it is.
  let svg = picture.svg(a_question(Move))
  assert string.contains(svg, "What&apos;s your play?")
  assert !string.contains(svg, "What's your play?")
  assert picture.escape("a < b & c > \"d\"")
    == "a &lt; b &amp; c &gt; &quot;d&quot;"
}

// ---------- What is refused ----------

pub fn a_board_that_is_not_26_ints_is_refused_not_drawn_empty_test() {
  let short = Question(..a_question(Move), board: [0, 1, 2])
  assert picture.checked_svg(short)
    == Error("a stored board has 3 entries, not 26")
  let assert Ok(_) = picture.checked_svg(a_question(Move))
}

// ---------- The default picture ----------

pub fn the_invite_picture_is_the_opening_position_with_the_invitations_words_test() {
  let svg = picture.invite_svg()

  assert count(svg, "class=\"checker white\"") == 15
  assert count(svg, "class=\"checker black\"") == 15
  assert checkers(svg, "white", "24") == 2
  assert checkers(svg, "white", "13") == 5
  assert checkers(svg, "white", "8") == 3
  assert checkers(svg, "white", "6") == 5
  assert checkers(svg, "black", "1") == 2
  assert checkers(svg, "black", "12") == 5
  assert checkers(svg, "black", "17") == 3
  assert checkers(svg, "black", "19") == 5
  assert count(svg, "class=\"die\"") == 0
  assert string.contains(svg, "class=\"cube\" data-owner=\"center\"")
  assert string.contains(svg, "take the other seat and roll")
  assert string.contains(svg, "Backgammon on Oskol")
  assert !string.contains(svg, "puzzles")
  assert !string.contains(svg, "Did you get this")
}

pub fn the_default_picture_is_the_opening_position_test() {
  let svg = picture.default_svg()

  assert count(svg, "class=\"checker white\"") == 15
  assert count(svg, "class=\"checker black\"") == 15
  assert checkers(svg, "white", "24") == 2
  assert checkers(svg, "white", "13") == 5
  assert checkers(svg, "white", "8") == 3
  assert checkers(svg, "white", "6") == 5
  assert checkers(svg, "black", "1") == 2
  assert checkers(svg, "black", "12") == 5
  assert checkers(svg, "black", "17") == 3
  assert checkers(svg, "black", "19") == 5
  assert count(svg, "class=\"die\"") == 0
  assert string.contains(svg, "class=\"cube\" data-owner=\"center\"")
  assert attribute(svg, "cube-value") == "1"
  assert count(svg, "class=\"count\"") == 0
}
