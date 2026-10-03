# The analysis board (backgammon)

Set up any position, ask the engine about it, play it out, and keep or share
the answer. Product intent: Aveline `analysis-plan` and the 2026-10-02 lines
in `decisions`; what each page shows a player: Aveline `pages` ("Analysis:
the board", "Puzzles: your own sets", "The replay: SHARE"). The wire is in
[api.md](api.md); own sets' rows and practice are in
[puzzles.md](puzzles.md#own-sets).

## At a glance

- **One page, `/analysis`** (☰, right after Puzzles), open to everybody:
  set a position up, ANALYZE it, play it out, SAVE it (an account), SHARE
  it. Doors in: `/analysis` (the opening), `?xgid=<id>` (any pasted id, and
  OPEN IN ANALYSIS from a replay step), `?p=<puzzle id>` (OPEN IN ANALYSIS
  from any puzzle).
- **An analyzed position is a puzzle row**, keyed on its question
  (`oskol/puzzles.key`). A key already answered -- by a game's review, a
  set, an earlier ask, a replay share -- answers at once and costs nothing.
  Only ANALYZE on a new key spends engine time, through the asker's line
  (two in flight, twenty waiting), the budgets (a guest 10 an hour and 30 a
  day, an account 30 and 150, everybody 600 a day) and a 60 s circuit. A
  page view never spends any; playing it out asks the server for legal plays
  (`POST /papi/analysis/moves`), never the engine.
- **Two share doors, one page.** SHARE on an answer and SHARE on a replay
  step both hand out `/puzzles/<id>`: the ordinary puzzle page, which names
  nobody and unfurls with the board. A replay share is written from the
  game's stored review, never the engine; its page adds WATCH THE REPLAY.
  Neither enters anybody's practice (no source row) or TRY ONE (`origin`).
- **Saving** is the save sheet (`Ui.SaveToSet`), from the answer and from
  every puzzle's reveal, into an account's own sets, which are practiced as
  Openings is. A guest's SAVE is the sign-in, with the position kept in the
  URL.
- **Words.** To a player a collection is a *set* ("Your sets", "Save to a
  set", "New set"); `deck` is code and URLs only. Nothing a player reads
  says card or deck.

Sections, in the order a position travels: the setup (Gleam, then the
client), the position id, the route, asking the engine, the board, the two
doors from the replay and the puzzle page, sharing from the replay, the
answer, playing it out, own sets, and the tests and screenshots.

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
  which `handlers/puzzles.describe` now calls too. A take's cube is the
  one before the double, said as such: "Cube at 2, Black's, redoubled to
  4.", "Cube centered, doubled to 2."

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

- A cube at 1 (exponent 0) is in the middle whatever the owner field
  says: an id naming an owner there reads as centered.
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
would drop it. The server serves the shell for `/analysis`
(`SpaController.analysis`: title "Analysis", one head and one canonical
for every position, indexable, in the sitemap); ☰ has Analysis right after
Puzzles (`nav-analysis`).

## Asking the engine (`src/oskol/handlers/analysis.gleam`, `Oskol.Analysis.Asker`)

`POST /papi/analysis` asks about one set-up position; `GET
/papi/analysis/:key` says where the ask stands (wire: `docs/api.md`). Tests:
`test/oskol/analysis_handler_test.gleam` (every decision, on stubs) and
`test/oskol/analysis/asker_test.exs` (the real line, the stub engine).

- **An analyzed position is a puzzle row.** The question
  (`setup.question`) is the key (`oskol/puzzles.key`), so a position asked
  before -- a game's mistake, a set's position, an earlier ask, by anyone --
  is answered at once from its row (`puzzles.by_key`) with a 200 and costs
  nothing. Only a key with no complete row goes to the engine. The answer
  is written once (`puzzles.store_one`, origin `analysis`), public like
  every puzzle, never rewritten (a complete answer may upgrade an
  incomplete one, as everywhere); its picture is drawn on the spot
  (`puzzles.pictures_one`) so a link shared a second later unfurls with the
  board. A key already stored keeps its row, its id and its origin.
- **`puzzles.origin`** (`game` | `set` | `analysis` | `replay`), set once by
  whichever write got the key first. TRY ONE and the status page sample
  `game` and `set` only (`Oskol.Puzzles.sample/1`, `sample_move/0`), so a
  board nobody meant for a stranger is never handed to one; TRY ONE also
  skips any row with a replay link (`puzzles.replay`, below).
- **`prepare`** decides, in order: the setup decodes and passes `check`
  (else 422 with its sentence; a roll that plays nothing is 409 `dances`,
  "6-4 cannot be played from here", nothing asked); a complete row is
  `Cached`; a key the asker already holds is `Joining` (free); the asker
  asleep is 503, full is 429 "The engine is busy. Try again in a minute.";
  and only then is one ask reserved from every bucket (`allow_ask`),
  refused as a 429 that says whose budget and how long. The request is
  `analysis.position_request(turn, 1, jacoby)`: the engine's default depth
  (4-ply), `all_results`, the top five, and `include_luck: false` and
  `rolls: false` (either is a cube evaluation per turn that nothing here
  reads). A game's own turns keep `one_turn_request`, luck and grid and all.
- **The budgets** (`buckets`; numbers from `config :oskol, :analysis_budget`):
  a guest `analysis:guest:<id>:hour` 10 and `:day` 30; an account
  `analysis:user:<id>:hour` 30 and `:day` 150 (an account is charged as
  itself, not as its browser); everybody `analysis:global:day` 600. The
  limiter is the sign-in one generalized (`Oskol.Limiter.allow/1`: per
  node, in memory, atomic over all buckets, fixed windows); it logs
  "analysis limited: guest|user|global" once per window. A restart resets
  the counts: a spend guard, not billing. A limiter that cannot be asked
  fails **closed** for asks (429 "The engine is busy", 30 s) and open for
  sign-in mail. An ask that was charged and never reached the engine is
  handed back (`release_ask`, `Oskol.Limiter.release/1`): the asker full or
  asleep when it was submitted, or a waiting job failed by the circuit. Two
  first POSTs of one key that race past `asking` may both stay charged.
- **`store`** keeps an answer only if it can grade any attempt: a move
  answer must hold every legal play and a board on every candidate
  (`practice/openings.answer`, the sets' own rule); a cube answer must
  carry the chances it was judged on (`extract.cube_answer`). Anything else
  is an `Error` and nothing is written.
- **The asker** (`lib/oskol/analysis/asker.ex`, a GenServer over the
  `Oskol.Analysis.AskerSupervisor` task supervisor) is the line and nothing
  else: jobs keyed by the puzzle key (a second ask joins), `in_flight` 2 and
  `waiting` 20, each task `Oskol.Reviews.ask_status("/backgammon/review",
  body, ask_timeout_ms)` then Gleam's `store`. A 4xx from the engine
  (`{:rejected, status, detail}`: it read the position and will not answer
  it, which a player-built board can provoke) fails that key alone with
  "The engine could not read this position. Check the board and try
  another." and is logged; it never opens the circuit. A 5xx, a timeout or
  no connection (`{:error, _}`) opens the circuit for `circuit_ms` (60 s),
  as the Grader's does: every
  POST in that window is a 503 at once and the jobs waiting fail with the
  same sentence, so a sleeping desktop is asked once. A task that crashes
  or whose answer `store` refuses fails its key with "The engine could not
  answer that one. Try again." Outcomes sit in a public ETS table (`{key,
  status, puzzle id | message, at}`) for ten minutes; a restart forgets
  them (a polling page then gets a 404 and asks again, which an answered
  key serves from its row). Config `config :oskol, Oskol.Analysis.Asker,
  enabled:, in_flight:, waiting:, circuit_ms:, ask_timeout_ms:`; off in
  tests (jobs are taken and never asked) unless a test turns it on.
- **The reveal** (`handlers/puzzles.reveal_json`) is `{best, top, cube,
  n_legal, levels}`; `best`, `top` and `cube` come from the same
  `answer_fields` an attempt's reveal is rendered with, so a page draws an
  analysis and an answered puzzle with one renderer.

## Per-roll grids (`src/oskol/analysis/rolls.gleam`, `Oskol.Analysis.Rolls`)

`POST /papi/analysis/rolls` answers how each of the 21 distinct rolls fares
from a board -- the grid behind a temperature map -- and, given the boards one
or two plays left, each play's grid and the difference between them (wire:
`docs/api.md`). The research is the Aveline doc `bg-roll-breakdown`; what is
settled there is not reopened here. Tests:
`test/oskol/analysis/rolls_test.gleam` (the weights, what a cell is, the sign,
on real grids), the same path in `test/oskol/analysis_handler_test.gleam`
(what is asked, on which cube, from which side, and what it costs) and
`test/oskol/analysis/rolls_test.exs` (the real call, the cache, the circuit).

- **Answered in the request, not queued.** A grid is about 0.2 s of engine
  time over the real path (measured 2026-10-02: 0.31-0.37 s for one board,
  0.38-0.52 s for a batch of two, against the live engine through Fly and the
  tailnet), so there is no job to join, nothing to poll and no second
  endpoint. The asker's **circuit** still governs it -- a desktop asleep
  behind a tailnet must be asked once and not once per keen player -- so
  `asking` is read before anything is asked (open is a 503, a full line a
  429), and a failure here opens it (`Asker.engine_failed/1`) exactly as a
  failed ask does.
- **3-ply, always** (`analysis.rolls_level`). At 4-ply the engine's per-roll
  rows are corrupt rather than imprecise -- nondeterministic between runs,
  about 0.09 low on ND, and they flip cube decisions -- and at 2-ply they are
  the bare network with no lookahead. The engine refuses both with a 422
  before any engine time; this constant is so nothing here asks. Only the
  no-double rows are read: the double/take rows are on another scale once the
  cube is owned or there is a match score.
- **A cell is the roll's own equity** (the human's call, 2026-10-02, after
  seeing the component): zero is an even position, and the page draws one
  fixed ramp over every grid -- 0 neutral, +1 the darkest green, -1 the
  darkest red, beyond that clamped. It was *luck* (the roll's equity minus the
  position's own) until then, which centred each grid on itself; an absolute
  scale reads the same everywhere instead, and the comparison grid uses the
  same ramp on the difference. The rows' weighted mean **is** the headline
  equity (verified against the live engine over twenty grids, worst
  disagreement 7.8e-08), so the grid is the number above it decomposed.
- **No band on the wire.** With a fixed ramp there is no decision left to
  centralise: a band would quantise the very number the page interpolates, and
  the one thing that must not drift between the replay, the analysis board and
  the comparison is the ramp, which is colour and lives with the colour
  (`docs/api.md` states it). It also means the engine's own 0.02-0.15 error
  against a rollout moves a cell's colour imperceptibly rather than flipping a
  bucket. A cell is **not a grade** either: `??` / `?` / `?!` measure a play
  against the best play and the engine plays the best move for every roll, so
  no cell holds a mistake; the only number here a grade could describe is a
  difference grid's total, which is graded where plays are graded.
- **What an absolute ramp costs, measured.** Over twenty live 3-ply grids a
  single position's 21 rolls span a median 0.60 of the 2.0 ramp (worst 1.19,
  and 0.0 in a decided position), and in 12 of the 20 -- 6 of the 14
  non-decided -- *every* roll falls on one side of zero: a winning position
  draws an all-green map whose rolls differ by a shade, which is the thing the
  headline already says. The difference grid is the opposite: the real
  comparison in the fixtures spans 1.39 of the ramp and uses it well. Worth
  knowing before anyone concludes the component is broken.
- **The sign is the hazard.** A candidate play's grid is taken on the board
  that play left, read from the **opponent's** side, so good for them is bad
  for the player who moved. `rolls.opposite` turns a position round (the
  board through `puzzles.flip`, the cube's owner and the away scores with it)
  and `rolls.diff` negates once more, so a difference cell is positive where
  the second play does better for the mover. Both are held to positions whose
  answer needs no engine: 6-6 is the best opening roll there is, and a play
  that leaves the opponent on the bar with blots to shoot at is worse on
  exactly the rolls that let them hit (and better on the ones they dance on).
- **The cube a grid is taken on** (`setup.grid_position`): the setup's own for
  a move and for a double -- a cube question is asked before the cube is
  turned, so its grid is the pre-roll board -- and for a take what the take
  left, twice the value owned by the taker, which is the engine's own rule for
  everything after a take. A roll that plays nothing is **not** refused here,
  unlike an ask: a grid is about all 21 rolls and not about the one that is set.
- **Cached by the request's bytes** in `roll_grids` (`Oskol.Analysis.Rolls`),
  as a turn's grade is in `turn_grades`: board, cube, match score and depth
  are all in those bytes, a row is never rewritten, and the rows are swept
  after a week. A board already stored costs **no engine time and no budget**,
  which is why the lookup is its own capability (`cached_rolls`) and the ask
  another (`ask_rolls`): the handler has to know a request is free before it
  charges anybody.
- **The budget** is the moves' shape rather than the asks': a caller's minute
  (`rolls:user:<id>:minute` or `rolls:guest:<id>:minute`, 30) and everybody's
  (`rolls:global:minute`, 120), from `config :oskol, :analysis_budget`. One
  charge a request, whether it asks about one board or two, because a
  comparison is one press; a charge for an ask the engine refused or never
  answered is handed back.
- **The replay reads its grids off the stored report** and spends no engine
  time (`docs/reviews.md`): every review graded from now on carries a grid on
  every turn, free, because the engine already computes it for luck. The 68
  games reviewed before that have none and cannot be backfilled, so the
  replay's ROLLS tab asks this endpoint for those on demand.

## The board (`assets/src/Page/Analysis.elm`)

The page wears the site's bar and the replay's page (`.rp-*`), the board
the puzzle page's size upright, in the visitor's board colours, White at
the bottom. Upright: the brushes, the board, then the settings strip, the
quick starts and the position id, the line, ANALYZE, and the answer's
place (`#an-panel`). Sideways the board takes the screen's height and the
rest is the column beside it; on a desktop the brushes sit over the board
and the column is beside both.

- **The board** is `View.viewEdit`: the still slab (`Setup.snapshot`: the
  two colours as players `white` and `black`, the cube as the setup has
  it, a take's double parked in the middle, the dice of a picked roll)
  whose points and bar halves are the slab's own elements, each with an id
  (`#an-pt-1`..`#an-pt-24`, `#an-bar-white`, `#an-bar-black`) and pointer
  listeners, so a tap lands where the point is drawn at every size.
- **Brushes** (`#an-brush-white`, `-black`, `-remove`): a tap or left
  click adds one checker of the brush's colour; on the other colour it
  takes one of those off (painting over: black 3, 2, 1, then white 1, 2);
  the x takes one off whatever is there. A right click (contextmenu
  prevented) and a long press (500 ms without sliding 10 px) are the other
  colour's brush; with the x both buttons remove. A phone that also sends
  contextmenu for a long press acts once, whichever comes first, and a
  late contextmenu for a finger's press that was dropped (a scroll, a
  pointercancel) paints nothing. The hint beside the brushes has a short
  form for phones under 360px, so it is never cut off. A mouse
  acts on release over the point it pressed; a finger that slides is a
  scroll. A sixteenth checker is refused and that colour's tray flashes
  (`an-flash-<color>-<parity>` on the page). `Page.Analysis.paint` is the
  rule, pure.
- **Every checker is somewhere.** Each colour's fifteen are on the board,
  borne off, or **not placed** yet. `Setup` cannot say "not placed" (to it,
  and to the server, off is whatever is not on the board), so the page
  keeps each colour's borne off itself (`Model.off`, `Off`) and derives
  the rest (`toPlace`). A checker taken off the board -- painted over, the
  x -- is not placed, never borne off; a checker put on comes from the not
  placed, or with none from the tray. The trays are places
  (`#an-off-white`, `#an-off-black`, which say "3 off" in a held slot): a
  tap bears one not-placed checker off, the other button, a long press or
  the x takes one back. Each brush wears its colour's not-placed count
  (`#an-left-white`, `#an-left-black`, a floating badge, hidden at 0). The
  pip counts are held to their widest so the trays beside them never move.
  CLEAR makes all thirty not placed; OPENING places them all; FLIP swaps
  the trays; every door in (`?xgid=`, `?p=`) has nothing not
  placed, so its off is fifteen less the board (`offFrom`).
- **Whose move it is**, at a glance and everywhere the page shows it. TO
  PLAY (`#an-turn`) is two buttons, each the colour's checker as the
  board draws it with its word (`#an-turn-white` "WHITE",
  `#an-turn-black` "BLACK", heard as "White to play"); the chosen one is
  the highlighter with an ink ring and its word underlined in ink. A
  brush, TO PLAY and a step of the line are all chosen that way, never as
  an inverted tile (a white checker on a dark square reads as the other
  colour). On the board the mover's bar is the live game's to-move bar,
  highlighted with its ▸, and says "to play" by the name, in SET UP
  (`View.viewEdit`) and PLAY alike (`View.viewStillTurn` for a picture,
  the table's own for a roll); the dice sit on the mover's half as the
  live game puts them. SET UP keeps White at the bottom; PLAY puts the
  actor there. The plates draw the colour as a checker in place of W or
  B. The bars never set the slab's width, so "to play" moving from one to
  the other moves nothing; under 360px the pip counts make room for it.
- **The strip** (`#an-strip`), three rows at every width (TO PLAY and the
  ask; the cube and the game; the scores and Crawford), every control a
  fixed width: TO PLAY; the ask (`#an-ask`): ROLL
  (`#an-dice`, opening `#an-roll-sheet`, the 21 rolls, a bottom sheet on a
  phone and a card wider; stored high die first), DOUBLE?
  (`#an-ask-double`), TAKE? (`#an-ask-take`); CUBE (`#an-cube` cycles 1, 2
  ... 64) and its owner (`#an-cube-owner`, disabled at CENTER at 1; a cube
  turned off 1 goes to whoever is acting, the player to play or for a take
  the doubler, so the strip never makes a cube `check` refuses); GAME
  (`#an-game`, UNLIMITED or MATCH TO n, inside the `#an-length` stepper,
  1..25), the scores (`#an-score-white`, `#an-score-black`, 0..n-1) and
  CRAWFORD (`#an-crawford`, which can be turned on only while somebody is
  one away and off at any time; it is turned off when nobody is). The
  match's controls stay in place, disabled, in unlimited play. Every door
  in (`?xgid=`, `?p=`, MATCH TO coming back) and every edit runs
  the same `normalize`: Crawford only one away, a cube at 1 centered.
- **Quick starts**: OPENING (`#an-opening`: the checkers where a game
  starts, the cube in the middle; who is to play, the ask and the match
  stay), CLEAR (`#an-clear`: no checkers, the rest kept), FLIP
  (`#an-flip`, `Setup.flip`). The page shows no position id (the human,
  2026-10-02: the id row, COPY and IMPORT wasted space); a position comes
  in by `?xgid=` (OPEN IN ANALYSIS from the replay) or `?p=` (from a
  puzzle), and SHARE is the puzzle's link. The page root carries the id
  for the browser smokes alone (`data-xgid`, empty while a checker is not
  placed).
- **The line** (`#an-check`, two lines tall, always there): "Opening the
  puzzle…" while `?p=` is read, a door's refusal ("That puzzle is gone.",
  "That is not a position id") until the first edit, else what is left to
  place ("Place 3 more White checkers", "Place 3 more White and 2 more
  Black checkers"), else the first sentence of `Setup.check`. ANALYZE
  (`#an-analyze`) is disabled while the line says anything (`analyzable`:
  every checker placed or off, a roll for a move, `check` clear), so the
  page only ever sends a complete position, whose off the server's
  fifteen-less-the-board agrees with; pressing it is the next section.
  Every edit goes through one function (`edit`, or `editWith` where the
  trays change too) that clears the notice, and, when the position really
  changed -- a checker borne off or taken back counts -- the answer (a
  control that changes nothing, the turn already White, leaves it up).
- **Doors in.** `/analysis` is `Setup.opening`. `?xgid=` opens on the id
  as it is: an id with Black on roll stays Black to play (the board is
  not turned round; FLIP turns it). `?p=` reads `GET /papi/puzzles/:id` and opens
  `Setup.fromQuestion kind question` (the solver White at the bottom, a
  take from the taker's side); a missing puzzle opens the opening and says
  "That puzzle is gone." Nothing on the page spends engine time.
- **Nothing moves**: the controls' widths, the line's two lines and the
  brushes' row are fixed, and the sheet and the dialog float over the
  page. `playwright/test-analysis` asserts the boxes across every change.
- **Sideways** (a phone on its side, under 600px tall) the column beside
  the board is taller than the screen, so the board is sticky under the
  site's bar: scrolled down to the answer, the board, and a candidate shown
  on it, stay in view.

## Open in analysis (the replay and every puzzle)

Two doors onto the board, each a plain link in a new tab
(`target="_blank" rel="noopener"`), so the page it was opened from stays
where it was, and the position is in the URL (it survives a reload and
pastes anywhere). Neither spends engine time.

- **The record says which game is the Crawford game.**
  `backgammon/record.crawford_game(target, scores_before)` is the rule
  `state.next_game` applies (the first game after somebody reaches one
  away, and only that one; never a match's first game, never unlimited
  play), over the score each game began at. `handlers/record` writes
  `crawford` on every game of the record, live or read from rows, from
  the result lines' scores; `Replay.Game.crawford` reads it (false for an
  answer without it). Tests: `record_test` (a match to 3 played to 2-2,
  against the state's own flag) and `record_handler_test` (both paths).
- **`Setup.fromReplay : Record -> Game -> Int -> Maybe Setup`** (in
  `Setup.elm`, not `Replay.elm`: `Setup` imports `Puzzle`, which imports
  `Replay`) is a step's decision, not the board it leaves: a turn is a
  `Move` with its dice (high first) on the board the step before shows; a
  double a `Double` for the doubler on the board before it; a take or a
  drop a `Take` asked of the player who answered, the cube as it stood
  before the double; step 0 the start for whoever moved first, a `Double`
  where `canDouble` (the cube live) and else a `Move` with no roll ("Pick a
  roll"); a resignation or a result line `Nothing`. The cube is the
  snapshot's (a take turns it to the taker), the match is `record.target`
  at `Replay.scoresBefore` with the game's `crawford`, and the colors are
  the players' own (the replay's flip is the reader's). Every step's XGID
  decodes back to the same setup (`ReplayTest`).
- **The replay**: OPEN IN ANALYSIS (`#rp-analysis`) in a fixed-height row
  over the panel's tabs (`.rp-panel-head`), on every tab, to
  `Route.analysisXgid`; on a step that is no decision it keeps its place
  unseen (`.is-off`, a span), so nothing moves as the reader steps. SHARE
  sits beside it (below).
- **Every puzzle page**: ANALYSIS (`#pz-analysis`, one word and the
  new-tab mark so SHARE, SAVE and it fit one row at 320) after the
  reveal, beside SHARE and SAVE, to `Route.analysisPuzzle id` (`/analysis?p=<id>`).
- `playwright/test-backgammon-replay` opens a graded turn, a double, a
  take, a turn of the Crawford game and one after it, and checks the new
  tab's 24 points (read from the editor's targets), bars, dice, cube and
  owner, score and Crawford against the record.

## Share a position from the replay (`src/oskol/handlers/positions.gleam`)

SHARE (`#rp-share-position`, in `.rp-panel-head` beside OPEN IN ANALYSIS)
makes any graded step of a replay the same link a set-up position shares:
a puzzle page that unfurls with the board and the question, names nobody,
and can be played on the spot. `POST /papi/games/:slug/rooms/:id/positions
{game, step}` (wire: `docs/api.md`). Tests: `test/oskol/positions_test.gleam`
(every decision on stubs, over the seeded match 821900's records, reviews and
log), `test/backgammon/analysis_test.gleam` (`turns_from_record` against
`games` over played games of every format),
`test/oskol_web/controllers/api/positions_api_test.exs`, `ReplayTest`,
`PuzzlePageTest`, `playwright/test-backgammon-replay` part 7.

- **Never engine time.** The row is written from what the game already left
  behind: the stored record gives the position, dice, cube and score; the
  stored review (`analysis.stored_one`, one game's row) gives the engine's
  answer for that turn. Nothing on this path can reach the engine or the
  asker, and no budget is charged. A step whose game has no done review
  (the game on the board, a review pending or failed) is 409 `not_graded`,
  "This position will be shareable once the game is graded."; the page says
  "Graded soon" and waits for the review (about a minute behind the last
  move) rather than asking.
- **No replay of the log.** `backgammon/analysis.turns_from_record` reads a
  finished game's turns off its stored record lines, through the same
  `settle` the log replay uses (a dead-cube double folded away the same
  way), so each turn is exactly the one `analysis.games` lists (`log_index`
  aside); the stored answer is zipped against them as `extract` zips it.
  The question is `puzzles.question_of` on that turn -- a roll is the
  checker play on the board before it, a double the doubler's call, a take
  or a drop the answer to the double -- so **a mistake shared this way is
  the very row `extract` wrote** (same key; it keeps its origin and
  sources). Away scores come from the previous game's result line, Crawford
  from `record.crawford_game`.
- **Trust.** A checker play must carry every legal play and a board on
  every candidate (`openings.answer`, the analysis board's and the sets'
  rule; the reveal lists the top five, never the move that was played); a
  cube answer its chances. Short of that is 409 `incomplete` ("This
  position's answer is incomplete; open it in the analysis board
  instead."), nothing written -- every answer from before `all_results`.
  Step 0, a resignation, the result, a forced roll, a dance and a double the
  engine does not grade are 409 `no_decision`; a room, game or step that
  names nothing 404. A roll played after a taken double is asked on the
  cube it was played on -- doubled, and the opponent's
  (`analysis.played_on`) -- exactly as `extract` asks it, so the keys agree
  and the share is the puzzle already written. A
  record row that will not read is a 500, never a skipped game (it would
  move every later game's number and score).
- **A budget.** Past `allow_ask` with `positions.buckets`: 30 an hour per
  caller (the account, else the guest id) and 1000 an hour for everybody,
  under `analysis:` so the limiter fails closed. Charged only for a share
  that would be written; refused, a 429 in a player's words.
- **Written once, nobody's practice.** `puzzles.store_one(puzzle, "replay",
  Some(ReplayLink))` writes the row with `origin = 'replay'` and
  `puzzles.replay = {slug, id, game, step}`; a key already stored keeps its
  row and its origin and gets the link only if it has none. A position a
  universal set holds (`origin = 'set'`, or any `deck_puzzles` row under a
  deck that is not somebody's own -- origin is only whoever wrote the key
  first) is never linked, and `replay_of` answers nothing for one linked
  before the set took it in: a set's learners did not come from that room.
  An own set is its owner's alone, so its positions may keep a link. Then
  `pictures_one` draws the unfurl picture.
  **No `puzzle_sources` row**, so it enters no deck and no story can be
  minted on it (`handlers/shares` mints only on the caller's own source:
  403). Idempotent: the same step is the same key is the same id.
- **Who may share**: anyone who can read the replay, which is anyone with
  the room's link (`handlers/record` asks no seat). The shared page names
  nobody; its way back (below) opens a replay the sharer could have sent
  anyway. TRY ONE never draws a `replay` row **nor any row with a replay
  link** (`Oskol.Puzzles.sample/1`), so a stranger handed a puzzle at random
  is never handed a door into somebody's room.
- **The way back.** `GET /papi/puzzles/:id` carries `replay: {path}` from
  the column (`puzzles.replay_of`); after the reveal the page says "From a
  game on Oskol · WATCH THE REPLAY →" (`#pz-replay`) onto
  `/<slug>/<id>/replay?game=n&step=s` -- unless the reader has the memory
  line (they played in it), which links to the replay already. The head,
  the picture and the canonical are the ordinary puzzle's.
- **The button.** One word, SHARE, because the head row is about 280 px on
  a 320 phone and both doors must fit: ready on a graded decision (posts,
  then `shareInvite` with `origin ++ url`: the share sheet on a phone, the
  clipboard elsewhere, "Link copied"); `is-soon` and quiet on a decision not
  graded yet, with "Graded soon" to its left where the row has room (a
  container query) and, pressed, the sentence; "Not graded" on a game whose
  review failed; "Analysis only" on a roll whose answer predates every play
  being sent (the review's `every_play`, a generated column on
  `game_reviews` served beside the rendered report), pointing at OPEN IN
  ANALYSIS beside it; unseen on a step that is no
  decision. What a share did floats under the head over the tabs
  (`#rp-share-note`), on that step only, and moves nothing.

## The answer (`Page.Analysis`, `Api.Analysis`, `Ui.Candidates`)

ANALYZE asks the engine about the position on the board, and the panel
under it (`#an-panel`) says what it answered, in the replay's words and
columns. Tests: `AnalysisPageTest` (on `AnalysisFixtures`, the server's own
`done` bodies), `WordsTest`, and `playwright/test-analysis` part 2.

- **The press.** `Api.Analysis.ask` posts `Setup.toJson`. A 200 is the
  answer at once (a position asked before: free). A 202 names the key, and
  ANALYZE's slot becomes a plate of the same size (`#an-asking`, "ASKING
  THE ENGINE… 3 s", the thin loading bar) while the page asks `GET
  /papi/analysis/:key` once a second (`Api.Analysis.status`, one request
  out at a time), for up to `pollLimit` (90) seconds, then says "The engine
  is taking too long. Try again in a minute." Every press is numbered, so
  whatever comes back for an earlier one (the position edited meanwhile)
  is dropped. A poll lost on the way is asked again at the next tick; a
  404 (the server forgot the key in a restart) posts again, which a stored
  answer serves at once.
- **When it cannot** (`#an-refused`): the server's sentence, word for
  word -- "6-4 cannot be played from here" (409 `dances`, nothing asked, no
  TRY AGAIN), a budget's sentence and its wait (429), "The engine is
  asleep. Try again in a minute." (503, or a `failed` key the circuit
  failed), the asker's own for a key that failed. TRY AGAIN (`#an-retry`,
  a fixed width) waits out `error.retry_after_s` (`Api.Analysis.Refusal`
  reads it off the envelope; `Api.send` is the request with the page's own
  expect), its label counting down ("TRY AGAIN · 42 s", "· 14 min").
- **The panel** (`#an-answer`, the replay's `.rp-note` box): for a move,
  `Words.bestInWords` -- "The best play is 8/5 6/5: 54.1% wins, 15.3%
  gammons, 10.2% gammons against." -- over the candidate table
  (`#an-candidates`). For a double, `Words.cubeLine` (the three equities,
  the pick in green), `Words.cubeChances` and `doubleWhy` / `noDoubleWhy`
  with the real colours (the one asked, then the other); for a take,
  `answerWhy`. The pick and the words are the call read off those very
  equities (`Puzzle.optimalOf` on `Replay.cubeCall`; docs/puzzles.md), so
  ND +0.221, D/T +0.224 is a double/take in ink and, being under 0.02,
  "Too close to call: doubling gains just 0.003, so either is fine. If
  doubled, Black takes." -- never "not a double". Under it the quiet line (`#an-depth`): "4-ply · asked just
  now", or "already analyzed" when the POST answered at once, the depth
  from `reveal.levels` (moves for a move, cube for a cube; "Already
  analyzed" alone when the row does not say), and SHARE's word on its
  right (`#an-share-note`).
- **The candidate table is one renderer** (`Ui.Candidates`): the replay's
  note, the puzzle reveal and this panel each build `Row`s (which is on the
  board, which was played, what a tap does) and it draws them the same way
  (`.rp-top`, `button.rp-cand` with `data-rank`; the replay's ids and the
  reveal's `#pz-candidates` / `data-yours` unchanged). A row puts its play
  on the board (`showing`): the board glows as the replay's does, with
  "BEST PLAY" / "ENGINE'S #3" over it, and the panel's sentence is that
  play against the best (`candidateInWords`). The dice (`#an-dice-toggle`,
  over them), the same row, or a tap anywhere on the board take it back;
  that tap paints nothing. A candidate's board is the mover's drawn as
  White, as every puzzle is, so for Black to play it is turned back round
  (`shownSetup`).
- **SHARE** (`#an-share`) hands `origin ++ /puzzles/<id>` (the row the ask
  stored) to the `shareInvite` port: the native sheet on a phone, else the
  clipboard, and "Link copied" in the quiet line for two seconds. That page
  is the puzzle's own, its head the question ("White to play 3-1. What's
  your play?"), the score and the cube, the picture drawn at the write; it
  names nobody, and an analyzed position has no source, so nobody can mint
  a story ("... got this wrong") for it. OPEN AS PUZZLE (`#an-open-puzzle`)
  is the same link in a new tab. The buttons (`#an-actions`) are a grid
  of fixed cells: PLAY THIS (or PLAY BEST, or PLAY IT OUT, below) across
  the first row; SAVE, SHARE and OPEN AS PUZZLE as three equal cells in
  the second, or SAVE and SHARE with OPEN AS PUZZLE under them where the
  panel is under 420px wide (a container query on the grid).
- **SAVE** (`#an-save`) opens the save sheet (`Ui.SaveToSet`, the same one
  a puzzle's reveal opens with `#pz-save`) with the answer's puzzle id: the
  account's sets with a check where one holds it, a tap putting it in or
  taking it out, "New set" with CREATE, and one line ("Saved to Openings I
  like · 12 positions"). A guest reads "Sign in to keep this position."
  over the sign-in, whose `next` is `/analysis?xgid=<this position>`, so
  nothing is lost; signed in there, the shell takes the account
  (`Page.Analysis.updateWithOut` hands the shell `SignedIn`) and the sheet
  goes on to the sets. The sheet floats (a sheet from the bottom on a
  phone, a card in the middle wider), so nothing under it moves. See
  [puzzles.md](puzzles.md#own-sets).
- **Nothing moves.** The plate is ANALYZE's box; the panel holds a
  `min-height` (28rem) at every size, the tallest answer (a sentence over
  five rows, the line and the two rows of buttons), so the page is as tall before the
  answer as after it, and filling, showing a candidate or clearing moves
  nothing; the TRY AGAIN countdown is a fixed width. Before any press the
  panel says where the answer will land. A guest analyzes as an account
  does (the budgets are the server's); only SAVE asks anyone to sign in.
- **The smoke's engine.** `playwright/test-analysis/setup.exs` starts
  `Oskol.EngineServer` (`test_support/engine_server.ex`), a Bandit on
  `ANALYSIS_STUB_PORT` (`PORT + 10000`) that answers as
  `Oskol.CompleteEngine` does (`prefer: ["8/5 6/5"]`, each answer held
  1.5 s), in a VM of its own; `run.sh` and `bin/check --browser` point the
  server's `ANALYSIS_URL` there, so no smoke reaches a real engine.

## Playing it out (`Page.Analysis`, `Setup.next`, `POST /papi/analysis/moves`)

From a complete position the board can be played on: a move, the next
roll for the other side, ANALYZE again, and back along the line. It is
all client state: a line, not a tree; nothing is a game, nothing is
persisted, the URL keeps the position the page opened on, and the dice
come from the browser (`elm/random`), since it is a sandbox. Tests:
`AnalysisPageTest` (`theNextPosition`, `playingItOut`),
`analysis_handler_test.gleam` (the moves), `asker_test.exs` (the route),
`playwright/test-analysis` part 3.

- **The line** (`Model.line : {steps, at}`, `Step = {setup, answer,
  chosen}`). Step 0 is the position set up. The step on the board lives
  in `setup`, `off` and `ask` as before, and `lineNow` writes it back, so
  walking away from a step keeps its answer. `chosen` is a
  `Setup.Chosen`: `Played {notation, board}` (the board the play leaves,
  the mover drawn as White, as a candidate's position and a tree node
  are), `Doubled`, `NoDouble`, `Took`, `Passed`.
- **The next position** (`Setup.next : Chosen -> Setup -> Result String
  Setup`, pure): a play puts the board in (turned round for Black,
  `Setup.withBoard`) with the other colour to play and no roll yet; NO
  DOUBLE is the same colour to roll; DOUBLE is the other colour asked to
  take, the cube as it stood (as `Setup` keeps a take); TAKE is the cube
  doubled and the taker's, the doubler to roll; PASS ends the line, "Black
  passes. White wins 1 point." (the cube's value), and so does a play
  that bears the mover's last checker off ("White has borne off.").
- **Choosing.** Under a move's answer PLAY THIS (`#an-play-candidate`)
  plays the candidate on the board, or with none shown the best (its
  label then PLAY BEST). The head's SET UP / PLAY (`#an-mode-setup`,
  `#an-mode-play`; PLAY only for a complete position) says what the board
  does. In PLAY the board is the puzzle page's table (`Puzzle.view`) on
  the roll's legal plays, with UNDO and PLAY in its band; PLAY commits the
  board the walk reaches, written as the record writes a turn
  (`Page.Analysis.notation`: one checker's steps joined, hits marked, the
  same move counted). The row over the board (the brushes' box,
  `#an-play-row`) says what the step asks: ROLL FOR ME (`#an-roll-random`)
  for a roll not picked, beside PICK A ROLL (`#an-roll-pick`, the roll
  sheet) and, where the cube lets the player double and the step before
  was not this player's NO DOUBLE, DOUBLE? (`#an-roll-double`, the step
  becomes the cube question); the table's hint; for a cube step "Double,
  or roll?" / "Take, or drop?", answered in the board's band with the
  live table's buttons (`cubeBoard`, `View.viewCubeAsk`: DOUBLE / ROLL,
  TAKE (CUBE TO n) / DROP; a double on offer drawn on the taker's side
  at the new value; the step's answer kept shown, the other faded); or
  the sentence the line ended in (`#an-line-end`). A cube answer's panel
  opens on what was asked, with its stakes, in the board's colours
  (`#an-answer-ask`, `Words.cubeQuestion`: "Black redoubles to 4.
  Take?"). Under a cube's answer PLAY IT OUT (`#an-play-out`)
  puts the board in PLAY. Every choice puts the board in PLAY. In PLAY the
  player acting sits at the bottom in their own colour, as at a table:
  the table can only be played from the bottom, so for Black the tree's
  points are drawn turned round (`Puzzle.Table.moverColor`).
- **PLAY plays; SET UP edits.** In PLAY the strip (`#an-strip`) and the
  quick starts' row are `<fieldset disabled>` (the strip faded where it
  stands, the quick starts in a disabled button's grey), so the position
  is changed only in SET UP.
  Every box is the same in both modes (part 3 asserts it, and that the
  fieldset is disabled in PLAY and live again in SET UP).
- **The legal plays.** No move generator in Elm. An answered step plays
  on its puzzle's own `tree` (lazy levels from `GET
  /papi/puzzles/:id/tree?node=`); any other step asks `POST
  /papi/analysis/moves` (`handlers/analysis.moves_json`): `setup.check`,
  a roll and not a cube question, one charge to the caller's minute
  (`moves:<who>:minute`, 120; `moves:global:minute`, 3000) in the same
  limiter as the asks, then `handlers/puzzles.tree_of` on the setup's
  question, kept under `setup:<key>` in the tree cache, so a lazy level
  (`{setup, node}`, `level_json`) is a lookup. Never the engine, nothing
  written; a roll that plays nothing is a root with no children, and PLAY
  passes the turn ("no play" on its plate). Only ANALYZE asks the engine,
  through the budgets, and every step is its own key, so a repeat is free.
- **Walking and changing.** The strip under the board (`#an-line`,
  `Ui.Scrub.row`: `#an-first`, `#an-prev`, `#an-next`, `#an-last` outside,
  one plate `#an-plate-<i>` per step between, the one on the board marked)
  reads "W 3-1 · 8/5 6/5", "B 6-2", "W to roll", "W doubles", "B takes",
  "B passes"; the plates scroll sideways at a fixed height, the one on the
  board scrolled into view. A tap walks with no fetch (an ask still out
  for the step left is dropped; asked again, the server has it). The same
  choice again walks on along the line as it was; a different one drops
  the steps after it. A new roll or cube question at a step (ROLL, ROLL
  FOR ME, PICK A ROLL, DOUBLE?, and in SET UP the strip's ROLL, DOUBLE?
  and TAKE?) drops the steps after it; any other change -- in SET UP a tap,
  the turn, the cube, the score, a quick start -- is another
  position and starts a fresh line from it.
- **Nothing moves.** The row over the board is the brushes' box in both
  modes, SET UP / PLAY are fixed widths, every button in the row is, the
  line is always there at one height with one plate or twenty, and the
  board keeps its box whoever sits at the bottom. On a desktop the line is
  under the board (the board's height allows for it); sideways it is in
  the column under the row, where it can be seen. Part 3 of the smoke
  asserts the boxes along the whole line at four sizes.

## Own sets

A set is an account's own deck: `decks` rows with an owner, its positions
`deck_puzzles` rows, its ladder the retain scope `deck:<id>`, practiced by
the same machinery as Openings. The analysis board reaches it through SAVE
(above); everything else -- the rows, the API, privacy, enrolment, the hub's
"Your sets" and the set's page with MANAGE -- is in
[puzzles.md](puzzles.md#own-sets).

## Tests and screenshots

- **Gleam**: `analysis_setup_test` (the setup, its checks and the question),
  `analysis_handler_test` (asking, the budgets, storing, the moves, on
  stubs), `positions_test` (a replay share), `record_test` and
  `record_handler_test` (the Crawford game), `analysis_test` (a record's
  turns), `own_decks_test` (making, filling and emptying a set).
- **Elixir**: `asker_test.exs` (the line, the circuit, the stub engine),
  `positions_api_test.exs`, `own_decks_test.exs`, `decks_api_test.exs`.
- **Elm**: `SetupTest`, `XgidTest` (the vectors and a fuzzer),
  `AnalysisPageTest` (the editor, the answer, playing it out), `WordsTest`,
  `ReplayTest` (`Setup.fromReplay` for every step), `PuzzlePageTest`,
  `PracticePageTest`.
- **Smokes**: `playwright/test-analysis` (four parts: setting up, ANALYZE,
  playing it out, SAVE and MANAGE; every box held at four sizes; its own
  stand-in engine) and `playwright/test-backgammon-replay` (OPEN IN
  ANALYSIS on a graded turn, a double, a take and the Crawford game; part 7,
  SHARE on the seeded match 821900 via `share_setup.exs`). Both run in
  `bin/check --browser` and in CI (the analysis board is a shard of its
  own; its server's `ANALYSIS_URL` names the stand-in's port, 14400).
- **The review tour**: `playwright/review-analysis/run.sh` serves its own
  port and database, arranges everything (`setup.exs`: the seeded match,
  the universal sets on the complete stub engine, an account whose set
  "Openings I like" `test.js` makes through the page's own API) and shoots
  every state at 390x844, 320x568, 844x390 and 1440x900 into
  `playwright/screenshots/review-analysis-<size>-<state>.png`: the empty
  board with ☰ open, a position half set up, the roll sheet, the import
  dialog, a move's answer, a candidate on the board (and, sideways, the
  board in view beside the answer), a cube's answer, a line of three steps
  in PLAY, the save sheet for an account and a guest, /puzzles with "Your
  sets", the set's page with MANAGE, the replay's head with SHARE and OPEN
  IN ANALYSIS, and a shared position's reveal with SAVE, ANALYSIS and
  WATCH THE REPLAY. `serve.sh` serves the same data, with the
  stand-in engine, until Ctrl-C, for walking it by hand (sign in as
  analysis-review@oskol.test from `/dev/mailbox`).
