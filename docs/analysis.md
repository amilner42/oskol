# The analysis board (backgammon)

Set up any position, ask the engine about it, and keep or share the answer.
Product intent and the wire: Aveline `analysis-plan` (and `decisions`). This
file grows a section per piece as the milestone lands.

## The setup (`src/oskol/analysis/setup.gleam`)

One shape for the position a player sets up, one set of rules for whether
it may be asked, and the question it asks. Every door into the board (the
editor, a puzzle id, a replay step) and every door out (asking the engine,
storing a puzzle, sharing) goes through it. Pure; tests in
`test/oskol/analysis_setup_test.gleam`.

- **The shape.** `Setup(points, white_bar, black_bar, to_play, ask,
  cube_value, cube_owner, match)`. `points` is 24 signed counts in Oskol's
  numbering, point 1 first, White positive and Black negative (White moves
  24 -> 1); borne off is whatever of a colour's fifteen is on neither the
  points nor the bar. `Ask` is `Move(dice)`, `Double` or `Take`; a move
  whose roll is not picked yet is `Move(no_roll)` (0-0). `cube_owner` is
  `None` for the middle. `match` is `Some(Match(length, white, black,
  crawford))`, or `None` for unlimited play, which is money play with the
  Jacoby rule, as every unlimited game here is.
- **Colours are real; `to_play` is the player being asked.** For a move or
  a double that is the player on roll; for a take it is the player who was
  doubled, and the doubler is the other colour.
- **The wire** (`to_json`, `decoder`): `{points: [24 ints], white_bar,
  black_bar, to_play: "white"|"black", ask: "move"|"double"|"take", dice:
  [a, b] | null, cube: {value, owner: "center"|"white"|"black"}, match:
  {length, white, black, crawford} | null}`. The decoder reads the shape and
  nothing more; a move with `dice: null` is `Move(no_roll)`, so that
  `check` can say "Pick a roll" rather than the decode failing.
- **`check(setup) -> Result(Setup, String)`** names the first thing that
  stops the position being asked, in one sentence, and refuses nothing
  else. In order: not 24 points (`points_message`); a count outside 0..15
  (`count_message`); "White has 17 checkers; 15 is the most"
  (`too_many_message`); "Put some White/Black checkers on the board"
  (`no_white_message`, `no_black_message`); "Pick a roll"; a die outside
  1..6; a cube value outside 1, 2 ... 64; an owner at 1 or none above 1; a
  match length outside 1..25; a score outside 0..length-1
  (`score_message(length)`); Crawford with nobody one away; a double, or
  the double a take answers, the doubler could not make by
  `analysis.engine_can_double` ("No double is possible here: the cube is
  Black's" / "...: this is the Crawford game" / "...: the cube already
  covers what White needs"); and "The game is over in this position". A
  colour with nothing on the board is "Put some ..." while the other colour
  has borne nothing off (a board being set up), and a finished game once it
  has. A point holding both colours and Crawford in unlimited play cannot
  be written in this shape at all. Fixed sentences are `pub const`s; the
  ones naming a colour or a number are functions.
- **`board(setup)`** places the checkers with the game's own ids, as
  `puzzles/tree.from_engine` does, so `backgammon/board` works on it.
- **`question(setup)`** is the stored `puzzles.Question`, mover-relative:
  the board through `analysis.encode`, dice high die first, away scores
  `length - score` each way (both 0 unlimited), `jacoby` exactly for
  unlimited, the cube owner from the mover's side. A take is stored from
  the doubler's side, as `puzzles/extract` writes one, so a set-up position
  and a game's own decision share one key, and so one puzzle row.
- **`turn(setup) -> Result(analysis.Turn, String)`** is the one turn an
  engine request is built from (`analysis.turns_request([#(1, turn)],
  jacoby, None, None)`), after `check`. A move names its first legal play as
  `played`, as `practice/openings.turn` does; a roll that plays nothing is
  `Error(dances_message)`, so nothing is asked. A cube ask has no dice, no
  played board and no double on it, from the doubler's side.
- **`from_question(q)`** is the way back, for `/analysis?p=<id>`: the solver
  as White at the bottom, as `handlers/puzzles.shown` draws it (a stored
  take comes back as a `Take` asked of White). A question keeps away scores,
  not the score, so a match comes back as the shortest one with those away
  scores (the length is the larger away; the player further away has 0).
  `from_question(question(s)) == s` for every such setup with White to play,
  and `flip(s)` for Black.
- **`flip(setup)`** swaps the colours: point p becomes 25 - p with its sign
  turned, and the bars, the cube's owner, the scores and `to_play` change
  sides. The question, and so its key, is unchanged.
- **`describe(setup)`** is the page's fixed line in the puzzle page's
  words, from `to_play`'s side and in real colours: "Match play, 5 away
  against 1, Crawford. Cube at 2, Black's." The words are `situation`,
  which `handlers/puzzles.describe` now calls too.
