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

## The setup in the client (`assets/src/Games/Backgammon/Setup.elm`)

The editor's record, field for field the Gleam `Setup` and the same JSON
(`toJson`, `decoder`). Two differences the client needs:
`Ask = Move (Maybe (Int, Int)) | Double | Take`, where `Move Nothing` is the
Gleam `Move(no_roll)` (no roll picked; `dice: null`), and
`fromQuestion : String -> Puzzle.Question -> Setup` takes the puzzle's
`kind`, because the question the page is sent (already `shown`, the solver
as White) cannot tell a double from a take on a centered cube. The match
comes back exactly as `from_question` builds it. `check` gives the Gleam
`check`'s sentences word for word and in the same order (the constants are
exported under the Gleam names in camel case) and is the fixed line under
the board; the server stays the authority. The one refusal it cannot give
is the dance ("That roll has no legal moves here", from `turn`): that
needs a move generator, and the client has none. Dice are kept high die
first.

## The position id (`assets/src/Games/Backgammon/Xgid.elm`)

XGID, eXtreme Gammon's position id, because it is what bgonline, Reddit, XG
and GNU Backgammon all read and write. `encode : Setup -> String`,
`decode : String -> Result String Setup`; every refusal is the one
sentence "That is not a position id". It is formatting, not rules: **the
server never reads an XGID**, and a position travels to it in the JSON
above.

```
XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10
     position:cube exponent:cube owner:turn:dice:X score:O score:rule flags:match length:max cube exponent
```

**Sources.** eXtreme Gammon's own description page no longer exists (404).
The fields were checked against GNU Backgammon 1.08's importer, `SetXGID`
in `set.c` and `PositionFromXG` in `positionid.c`, and against ids XG users
publish: the opening string as bug-gnubg and xgid2anki quote it;
`XGID=--A-bBBBB--BbB-----dbbc-B-:0:0:1:31:6:4:1:7:10` (backgammonforums,
"How to post positions": a match to 7 at 6-4, Crawford);
`XGID=-b----E-C---eE---b-d-b--B-:0:0:1:46:0:0:3:0:10` (bug-gnubg, 2010-06:
money with Jacoby and beavers, the low die first). The R package
lassehjorthmadsen/backgammon (`posid2xgid.R`) agrees on the cube exponent
and the `D` turn.

- **position**: 26 characters, always from X's side, whoever is on roll.
  Index 0 is O's bar, 1..24 are the points numbered for X (X moves
  24 -> 1), and 25 is X's bar. `-` is empty, `A`..`P` one to sixteen of
  X's checkers, `a`..`p` O's. Oskol's White is X (at the bottom, the same
  numbering) and Black is O. Borne off is whatever is missing from fifteen.
- **cube exponent**: the cube is 2 to that power. **cube owner**: 0
  centered, 1 X, -1 O.
- **turn**: 1 X, -1 O, the player on roll.
- **With dice `D` (a double offered), the turn names the doubler**, not the
  player asked to take (gnubg: `fTurn = !fMove`). **The cube fields are the
  cube before the double.** So White asked to take Black's redouble from 2
  is `:1:-1:-1:D:`. This is the field most easily got backwards.
- **dice**: two digits for a roll (either order read, high die first
  written). `00` means nobody has rolled yet (the player may double). `D` is
  above. `B` and `R` (beaver, raccoon) are refused.
- **scores**: X's, then O's, in points won. Money play writes `0:0`, and
  they are read past there.
- **rule flags**: in a match, 1 is the Crawford game and 0 is not (anything
  else is refused, as gnubg does). In money play, bit 1 is Jacoby and bit 2
  is beavers.
- **match length**: 0 is money play. **max cube exponent**: XG writes 10
  and gnubg ignores it. We write 10 and read past it (it must still be a
  number).

Oskol's choices on top of the format:

- Unlimited play writes flags 1 and length 0. Any money id is read as
  unlimited play (Jacoby, no beavers), the only money game Oskol plays.
- `Move Nothing` writes `00`. `00` reads back as `Double` where the player
  on roll could double (`Setup.canDouble`), and as `Move Nothing` ("Pick a
  roll") where they could not, since to XG it only says nobody has rolled.
- Refused:
  - a wrong length or field count
  - a character outside the alphabet
  - X on O's bar, or O on X's
  - more than 15 of a color
  - a die outside 1..6
  - a cube owner or turn outside the set
  - `B` or `R`
  - a cube past 64 (the editor's cube stops there)
  - a field that is not a number

  A score at or past the match length, or Crawford with nobody one away,
  decodes, and `check` says what is wrong.
- `decode (encode s) == s` for every setup `check` accepts (`XgidTest`,
  a fuzzer over `SetupFuzz`).

## The route

`Route.Analysis (Maybe String) (Maybe String)` is `/analysis?xgid=&p=`,
parsed before the `/:slug` catch-alls. The builders are `Route.analysis`,
`Route.analysisXgid : Setup -> Route` (through `Xgid.encode`) and
`Route.analysisPuzzle : String -> Route`. `href` percent-encodes the id's
`=` and `:`, and `fromUrl` reads them back. It also reads a hand-typed
`?xgid=XGID=...` with a bare `=` the same way; `Url.Parser.Query` alone
would drop it. Main shows the not-found page for the route until the page
lands (analysis-page-editor).
