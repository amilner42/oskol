# Testing

One layer at a time, and the seams between them. The commands are in
`AGENTS.md`; this is what each suite covers, the fixtures, the Playwright
scripts and CI.

## The suites

Every game is its seed plus its action log, and the suite leans on that.

**Gleam (`bin/test-gleam`)**
- Rules in controlled positions: `test/backgammon/rules_test.gleam` and `cube_test.gleam`
  build boards to assert dice order, bar entry, bearing off, hits, gammons,
  doubling, Crawford, Jacoby, resigning.
- `test/backgammon/oracle_test.gleam`: an independent move generator,
  written from the rulebook on raw checker data, checked against
  `board.sequences` on hundreds of random boards (`positions.gleam` builds
  them) plus named positions with the expected sequences spelled out.
- `test/backgammon/properties_test.gleam`: staged-turn invariants over random
  positions (undo is an exact inverse, a legal first move never strands a
  die, pip accounting, commit) and a no-leak property over random games.
- Conformance (`test/backgammon/engine_test.gleam`): seeded playouts to
  game over with the game's invariants, replay determinism, malformed
  actions rejected. Random play excludes `resign` (`conformance.Options`).
- Golden replays (`test/gamekit/golden_test.gleam`): every file in
  `test/fixtures/replays` replays to its recorded fingerprint, and every
  registered format has one. A rules change fails here; when intended, run
  `mix oskol.fixtures replays` and read the diff.
- Clock tiers (`test/backgammon/clock_tiers_test.gleam`): the bank for every
  tier and format, unlimited refilling at each new game and a match not, a
  single game run out, a timeout late in a match, a replayed log landing on
  the same banks; old presets resolving unchanged.
- Framework units: rng, clocks (including the turn delay), action decoding
  and validation, `event.for_viewer`, host/protocol shapes.
- `test/backgammon/analysis_test.gleam`: the engine board in controlled
  positions, the cube and match state per turn, scripted logs (doubles,
  drops, resigns, timeouts), and the property that every
  played board is legal for its dice under an independent generator on the
  engine's own format; `test/oskol/reviews_handler_test.gleam`: when a
  review is owed, retries, and the page's shape, on stub caps.

**Fixtures (`mix oskol.fixtures`)** come from `gamekit/fixture`: replays are
small and committed; payload captures (every update every viewer received
for the first steps of a playout) are derived, gitignored, and embedded in
`assets/tests/Fixtures.elm` for elm-test. `oskol/puzzles/fixture` does the
same for the puzzle wire: `PuzzleApiFixtures.elm` (the question, per kind)
and `PuzzleRevealFixtures.elm` (an attempt's answer per verdict, from
`handlers/puzzles.attempt_body`: `move_pass`, `move_dubious`, `move_fail`,
`move_unknown`, `double_pass`, `double_fail`, `take_pass`, `take_close`,
`double_close_yes`, `double_close_no`, and the three schedule shapes),
`AnalysisFixtures.elm` (the analysis board's `done` answer, from
`handlers/analysis.done_fixture`: `move`, `double`, `take`,
`double_close` and `move_no_levels`), and `CubeCallFixtures.elm` (the
server's cube call on equities at, above and below each line,
`fixture.cube_calls`, which `CubeCallTest` holds `Replay.cubeCall` to).

**Elm (`elm-test`)**
- `ProtocolTest`: every fixture payload decodes; cross-checks that hold for
  any game (viewer matches seat, spectators have no legal actions, select
  candidates exist in their zone, ids unique per zone, events only name
  tokens the viewer can see).
- `BackgammonViewTest`: the view on real scenes, pure update logic, and
  rendered DOM facts (30 checkers, sources marked only for legal moves,
  buttons follow the legal actions), and the cube's hold: a tap shorter
  than `holdMs` sends nothing, a full hold sends once, leaving or a scroll
  cancels, Enter or Space held is the keyboard's way.
- `PlayUpdateTest`: fixture payloads replayed through `Page.Play.applyPayload`.
- `RouteTest`, `SessionTest`, `CatalogTest`: the client's routes round-trip,
  the boot flags, and the `/papi` envelope and decoders (which are lax about
  keys they do not need and strict about the ones they do).
- `GameLandingTest`: the guest home on decoded responses — OSKOL, the
  board, the sentence and its three menus (in the sentence's words), PLAY
  NOW against Sage at once (under the remembered name, else "Guest",
  never "Sage") and against a friend after the name dialog, the live
  games behind the bar's pill, SIGN IN; CREATE GAME's dialog as the
  signed-in home opens it (the mode and clock dropdowns, their defaults,
  the summary, inline validation); the theme picker; and the invite's
  three answers.
- `HomeTest`: the signed-in home on `/papi/me/home` as the handler writes
  it — each section and the order they come in (form first), each empty
  state, the form printing no numbers under three graded games, the streak
  in days and nothing at zero, a match drawn as one line that opens to its
  games, MORE appending the next page of rooms and then going, the grade
  band a rating is coloured by, a guest's answer handing the shell
  `SignedOut` rather than drawing an empty home, and the practice section
  as the one-tier card (its mark, what is left to master, TRAIN with its
  tier, the quiet rows and tapping one).
- `MistakesTest`: every word practice is said in, pinned -- the tiers by
  mark and name, "31 left to master" and "23 mastered", what a tier in good
  shape says and why, the all-clear line, the next tier's button, "3
  practiced today", a run of one reading as a finished thing and no run
  calling an answer close, what each of the four choices would do, the
  early and KNEW IT lines, the cost lines, and the hub's and a deck page's
  words, and that none of them says "fix", "patched" or "learned".
- `AnalysisPageTest`: the analysis board's editor: a tap adds the brush's
  colour and paints over the other one, a right click and a long press are
  the other brush (once, whichever comes first; a slide is a scroll), the
  x, the bar's halves, the sixteenth refused with its tray's flash, OPENING
  / CLEAR / FLIP, `?xgid=` and `?p=` on every `PuzzleApiFixtures` question, a gone
  puzzle, the check line's sentences and ANALYZE, CRAWFORD only one away,
  the cube's owner at 1, the match's bounds; every checker placed, borne
  off or not placed (a taken-off checker is not placed, the trays bear off
  and give back, CLEAR, the doors' off), and a fuzz over runs of every
  control: ANALYZE is on exactly when every checker is placed or off, a
  move has its roll and `Setup.check` is clear. The answer, on
  `AnalysisFixtures`: every one decodes; the plate counting seconds; pending
  then done (the best play in words, the table, "4-ply · asked just now");
  a cached answer at once ("already analyzed"); the double and the take; a
  candidate on the board and the dice taking it back (turned round for
  Black to play), a board tap while it is shown painting nothing; an edit
  clearing the answer and a no-op control keeping it; a stale press's
  answer dropped; a dance (no TRY AGAIN), the engine asleep (TRY AGAIN after
  its wait), a budget's wait, a failed ask, a forgotten key asked again, a
  lost poll, the poll limit; "Link copied".
- `WordsTest` also pins `bestInWords`, with and without chances.
- `PuzzlePageTest`: the page on the generated fixtures: the reveal decodes
  (a fifth verdict word fails it), a tap walks and UNDO walks back, a lazy
  node is fetched and merged, PLAY posts exactly the path with the key (and
  waits for the key), the verdict and "you" in the table, the cube scale
  with the engine's band, a dubious play a miss named by its band, the
  level line in its three states and after an override (an early answer,
  KNEW IT), SOONER / GOT IT / KNEW IT each posting on the tap, a second
  tap of another replacing it, the four disabled in flight, a refusal
  keeping the choice before it, NEVER needing YES, NEVER (any other tap
  takes it back), ANOTHER / I'M DONE waiting for a choice on its way, GOT
  IT barred after a miss, the same rows laid out whatever is tapped; ANOTHER and I'M DONE only from the shell, the memory line on 200
  and not on 404; the session strip (the deck's mark or name, its ring
  with the count, one row of tiles, the day's line, no total, practice
  only through PRACTICE ANYWAY); the end of a run: every verdict reported,
  a run of one reading as a whole session, the card for a guest (the
  sign-in, going on to where the run began) and for an account (the score,
  the way on -- KEEP GOING or PRACTICE ANYWAY, held in a fixed band -- and
  the way back), and what the run mastered.
- `PuzzlesHubTest`: the practice home on `/papi/practice/decks` -- five
  decks, one in front and four rows, for an account, a guest and a
  stranger: the lead or the one tapped, the grid and the ring, the one
  button in each state (TRAIN, KEEP GOING, PRACTICE ANYWAY, START,
  TRY) and what each press asks and hands the shell, the cost
  lines there and not there, a fresh account with the openings in front, a
  stranger's TRY ONE and the empty pool's sentence, and decoders that
  refuse a malformed count rather than defaulting it.
- `PracticePageTest`: a deck's page on `/papi/practice/decks/:slug` -- the
  card at page size for each of the five, the button in each state, where
  the positions stand, the month and the cost, a guest's tier, a
  stranger's, a set nobody has added.
- `RunTest`: a run as the shell drives it (`Run`): starting, answering,
  asking the queue again past its ids, KEEP GOING, PRACTICE ANYWAY, the
  way on from the end card, and celebrating exactly the counted answer
  that reaches today's target, once a run.
- `PuzzleCelebrationTest`: the today's-set-done card -- not in the
  reveal of the answer that did it, whose ANOTHER (even past the run's
  last id) or I'M DONE shows it in place of the puzzle (the card's own I'M DONE ends the run); never for a guest, once a
  page; "Keep going?"; hidden until the
  deck is read; the ring and check, the steps line, the won-back line, a
  set's words, the grid's stepping squares, KEEP GOING / PRACTICE ANYWAY /
  I'M DONE, paused until on screen, settled on the last keyframe, reduced
  motion settled at once.
- `DecksTest`, `ChartsTest`: the sets' words and decoders; the home's and
  the practice pages' pictures (the PR line, ladder, strip, band bar,
  mastery grid and ring).
- `ReplayTest`: the replay on the real record and analysis of seed 000011
  (`ReplayFixtures`): decoders, the board at every step, stepping, keys,
  swipes, game switching, and the analysis filling in without moving the
  viewer; polling only while something is pending.
- `WordsTest`: the verdict sentences where they are written, on made-up
  verdicts -- every move grade with its gains and costs, every cube call
  from both sides of the cube, the too-good rule, and the too-close-to-call
  words at, above and below each line (0.003, 0.019, 0.021).
- `XgidTest`: the position id pinned by vectors (the opening, Black to
  play, a cube owned by each side, a match with Crawford, a take, the bar
  and borne off, ids published by gnubg's bug list and backgammonforums),
  every refusal in its one sentence, and `decode (encode s) == s` over
  `SetupFuzz`'s valid setups.
- `SetupTest`: the analysis board's setup on the wire (the literal the
  Gleam decoder reads), `check`'s sentences, `flip`, and the puzzle
  fixtures opened on the board (`fromQuestion`).

**Elixir (`mix test`)**
- `test/oskol/room_test.exs`: `Oskol.Bots` (test_support) plays random
  legal actions through the room for every registered game and format,
  many rooms concurrently; disconnect, rejoin, rematch keeps the setup.
  Channel tests cover join replies, spectators, per-player payloads, and
  reconnects; `spa_controller_test.exs` covers what is still the server's on
  the two landing routes — the shell, the head a crawler reads, the 404 for a
  slug that names no game, the removed games' redirects, and the guest
  cookie and the name it remembers; `practice_page_test.exs` the same for
  `/practice/<slug>` (a set indexable and in the sitemap, a tier `noindex`,
  an unknown or unbuilt one a 404).

**Browser (`bin/check --browser`)**: Playwright smokes create real games and
play them; review scripts take screenshots for eyeballing. The ways into a
game live once, in `playwright/lib/flows.js`: `createGame` (a guest says it
in the home's sentence and presses PLAY NOW; an account uses ☰'s PLAY
and its dialog; by element id), `barItem` (anything in ☰), `joinByLink`, `joinByCode` and
`openSeat`, and `seatedContext` for a browser that already holds a seat.
DOUBLE, TAKE and DROP are held, not clicked: `hold(page, selector,
{ touch, ms })` presses past the 350 ms hold (a finger through CDP's touch
events with `touch`), and a short `ms` is the tap that must do nothing. A
smoke uses those rather than clicking through the home page itself, so a
change to the home page or the invite touches that one file. Two players
are two browser contexts: a seat is held by the browser's guest cookie, so
two pages of one context are one player.

When you add a rule, add a controlled-position test before the playouts:
the playouts prove nothing crashes, the position tests prove the rule is
right. A registered game's conformance test plus `mix oskol.fixtures` give
it golden replays and Elm contract coverage for free.

## Playwright scripts

`bin/check --browser` runs the smokes (`test-*`) in its own order against a
server it starts and stops. Each needs a running server otherwise (`PORT` or
`BASE_URL` picks it); the `review-*` scripts write screenshots to
`playwright/screenshots/` for eyeballing. How to write one:
`playwright/README.md`.

```bash
node playwright/test-accounts/test.js           # signing in: the code from LIVE GAMES, the
                                               # link (asks first), an owned seat nobody
                                               # can claim, log out; mail read from
                                               # /dev/last-login; phone screenshots
node playwright/test-home/test.js               # the signed-in home: the bar, the form's
                                               # numbers, streak and line, live games, the
                                               # practice line, ten recent rooms then MORE,
                                               # a match opening to its games, a tap into a
                                               # replay (it arranges its account)
node playwright/review-home/test.js             # screenshots of the signed-in home: full, a
                                               # match opened, empty, CREATE GAME, the
                                               # boards (4 sizes)
node playwright/test-backgammon-smoke/test.js   # backgammon: stage, undo, play, with a clock
node playwright/test-backgammon-board/test.js   # the classic board: cube fixture, centre band,
                                               # full-height bar, auto-roll
node playwright/test-cube-hold/test.js         # DOUBLE against Sage is held: a quick tap, click
                                               # or Enter does nothing, the bar fills with nothing
                                               # moving, a hold offers the cube once; one word at
                                               # five sizes (setup.exs arranges the room)
node playwright/test-guest-prefill/test.js      # the site remembers a guest's name (friend dialog,
                                               # PLAY NOW against Sage)
node playwright/test-clock-tiers/test.js        # the clock tiers at four sizes: the sentence's
                                               # menu and the line under it per format with every
                                               # box held, the friend dialog, PLAY's dialog (it
                                               # makes its own account), the lobby and the invite
node playwright/test-puzzles-cards/test.js      # PRACTICE THIS GAME'S N MISTAKES from both result
                                               # cards (setup.exs arranges and grades the games)
node playwright/test-landing-screenshot/test.js # Playwright itself works: one landing screenshot
node playwright/review-themes/test.js           # every board theme, shot on a phone; the pick
                                               # survives a reload
node playwright/test-backgammon-dance/test.js   # backgammon: a danced turn (it arranges the
                                               # room itself), the roll animation, the delay
node playwright/test-backgammon-landscape/test.js  # backgammon on a sideways phone, both layouts:
                                               # expanded (the board is the screen, the chrome on its
                                               # rails and never on the play) and compressed (the
                                               # board fits the screen height exactly, nothing scrolls);
                                               # the bear-off trays (a column at the home boards' end
                                               # off a portrait phone, strips upright) through a real
                                               # bear-off at six sizes with every box held still
                                               # (bearoff.exs arranges the room; playwright/lib/trays.js);
                                               # the clock as one line, AA on all twelve boards
node playwright/review-landscape-focus/test.js  # the review tour of focus mode at the phone sizes,
                                               # the trays asserted and a bear-off shot on each
node playwright/test-backgammon-replay/test.js  # the replay of a finished match (it arranges
                                               # the room): steps, keys, swipes, analysis
                                               # pending -> done, retry, phones, OPEN IN
                                               # ANALYSIS at a graded turn, a double, a take,
                                               # SHARE on the seeded match 821900
                                               # (share_setup.exs): the link copied, the
                                               # doors holding their boxes, the stranger's
                                               # reveal and WATCH THE REPLAY back to the step,
                                               # the Crawford game and after it (the board,
                                               # dice, cube, score in the new tab); the match
                                               # is searched for one with all of those; the
                                               # analysis is stubbed unless REPLAY_REAL=1
node playwright/test-puzzle/test.js             # a puzzle from a link: setup.exs arranges a game,
                                               # grades it against a Req.Test engine in its own VM
                                               # (real legal plays, the played one a mistake) and
                                               # extracts; a stranger, the opponent (memory line)
                                               # and the mistake's own player signed in (level
                                               # line; NEVER asking without a post or a height
                                               # change; KNEW IT / SOONER posted on the tap, once,
                                               # and explained) play it;
                                               # phones; the board is the table's size; a take of a
                                               # redouble at 390x844, 1440x900, 320x568, 844x390:
                                               # "Black redoubles to 4. Take?", the cube on offer
                                               # at 4 on White's side, TAKE / DROP in the band,
                                               # nothing moving through the answer (screenshots
                                               # in $SHOTS_DIR or $TMPDIR/oskol-test-puzzle)
node playwright/review-puzzle/test.js           # screenshots of the puzzle page: question, staged,
                                               # reveal, a candidate, a cube question (phone, small,
                                               # landscape, desktop)
node playwright/test-analysis/test.js           # the analysis board. Part 1, setting up: ☰ Analysis;
                                               # a desktop by left and right clicks, the x, the bar,
                                               # the sixteenth's flash, ROLL, the cube, DOUBLE? and
                                               # TAKE?, a match and Crawford, FLIP, whose move (TO
                                               # PLAY ringed not inverted, the bar to move says "to
                                               # play"); a
                                               # phone by taps and long presses (CDP touch); every
                                               # point hit where it is drawn at 320x568 and 844x390;
                                               # ?xgid= and a gone ?p=. The board, the strip, each
                                               # control, the line and ANALYZE keep their boxes
                                               # throughout. Part 2, ANALYZE, against a stand-in
                                               # engine (setup.exs starts `Oskol.EngineServer`, a
                                               # Bandit serving `Oskol.CompleteEngine`, on
                                               # ANALYSIS_STUB_PORT = PORT + 10000, which the
                                               # server's ANALYSIS_URL names): the plate in ANALYZE's
                                               # box, a fresh answer, a candidate and the dice,
                                               # "already analyzed", an edit clearing it; the
                                               # opening 3-1 with 8/5 6/5 first, SHARE's link, a
                                               # stranger's unfurl (naming nobody) and play to the
                                               # reveal; DOUBLE?; a dance; the panel at four sizes
                                               # with every box (the panel's too) held. Part 3,
                                               # playing it out, at four sizes: PLAY BEST on the
                                               # opening 3-1, ROLL FOR ME for Black, the table on
                                               # its legal plays (Black at the bottom), ANALYZE;
                                               # FIRST and NEXT with the answers kept and no ask;
                                               # Black's roll played by hand, the strip, the quick
                                               # starts disabled in PLAY, White's DOUBLE? from the row and Black's PASS
                                               # ending the line in its sentence; a different play
                                               # at step 0 dropping the rest; PICK A ROLL in PLAY;
                                               # SET UP live again, and an edit at a later step
                                               # starting a fresh line; the
                                               # board, the row over it, the line, ANALYZE and the
                                               # panel holding their boxes throughout. Part 4,
                                               # SAVE, with an account account.exs makes (its old
                                               # sets cleared): a guest's sign-in; the empty sheet at
                                               # four sizes with nothing under it moving; a new set
                                               # made and ticked, untick and tick, a taken name; the
                                               # set under "Your sets" on /puzzles, TRAIN to a reveal
                                               # whose SAVE has it ticked; the sheet, hub and set page
                                               # at four sizes; MANAGE: noindex, the 72px board,
                                               # rename, remove, delete (then 404). PART=2 runs parts
                                               # 2 to 4, PART=3 part 3 alone, PART=4 part 4 alone.
                                               # Screenshots: screenshots/analysis-*.png,
                                               # puzzles-your-sets-*, practice-own-*, puzzle-save-390.
                                               # `playwright/test-analysis/run.sh` serves its own
                                               # port and database around it; bin/check points its
                                               # server's ANALYSIS_URL at the stand-in's port, and
                                               # CI runs it as the `analysis` shard with the
                                               # server's ANALYSIS_URL at http://localhost:14400.
node playwright/test-puzzles-hub/test.js        # the practice home and a run: setup.exs's game, the
                                               # first seat trimmed to 12 mistakes; a stranger's TRY
                                               # ONE, a guest's run to the score and the sign-in ask,
                                               # sign in there (timezone sent once), the five decks
                                               # with the worst tier in front, TRAIN's run watching
                                               # the strip, I'M DONE after one, the run asking its
                                               # queue again, TRAIN's run whose ANOTHER brings the
                                               # today's-set card (same URL, centered at four sizes)
                                               # and KEEP GOING (3/6);
                                               # phones;
                                               # past the twentieth with many_due.exs (DUE_COUNT;
                                               # DUE_MODE=start_all leaves nothing new, for PRACTICE
                                               # ANYWAY). review-practice/serve.sh runs it on its own
                                               # port and database
playwright/review-practice/run.sh               # screenshots of /puzzles for every visitor and every
                                               # state of the deck in front, and each deck's own page
                                               # (/practice/<slug>), measuring that nothing moves (four
                                               # sizes); setup.exs and shape.exs (SHAPE_STATE ladder,
                                               # keep_going, scheduled, today_three) arrange them;
                                               # serves its own port and database
playwright/review-celebration/run.sh            # screenshots of the today's-set-done card at four sizes:
                                               # the reveal before it, ANOTHER to the card (same URL, board
                                               # gone, centered, settled in time), reduced motion, KEEP GOING then
                                               # ANOTHER, a set, an all-miss run; frames and a video;
                                               # its own port and database
playwright/review-run/run.sh                    # screenshots of a run: the strip, the refetch, the end
                                               # card's way on, an early answer, a set's run, past the
                                               # twentieth (four sizes); its own port and database
playwright/review-verdict/run.sh                # screenshots of the reveal's verdict in each shape, then
                                               # the four choices under the level line, applied on tap,
                                               # NEVER's confirm, the reveal's height held (four sizes);
                                               # serves its own port and database
playwright/review-decks/run.sh                  # screenshots of the sets on /puzzles, a run
                                               # through the openings, the reveal and the end
                                               # card (four sizes); serves its own port and
                                               # database and builds the sets on a stub engine
playwright/review-analysis/run.sh               # the Analysis milestone whole, at four sizes: the
                                               # empty board with ☰ open, a position half set up,
                                               # the roll sheet, Black to play, a move's answer and a
                                               # candidate (sideways: the board in view beside the
                                               # answer), a cube's answer, a line of three steps in
                                               # PLAY, the save sheet (an account, a guest), /puzzles
                                               # with "Your sets", the set's page with MANAGE, the
                                               # replay's SHARE and OPEN IN ANALYSIS, and a replay
                                               # share's reveal (SAVE, OPEN IN ANALYSIS, WATCH THE
                                               # REPLAY). setup.exs arranges the seeded match, the
                                               # universal sets (stub engine) and an account; test.js
                                               # starts the stand-in engine and makes the set.
                                               # screenshots/review-analysis-<size>-<state>.png;
                                               # serves its own port (4487) and database.
                                               # review-analysis/serve.sh serves the same data and
                                               # engine until Ctrl-C, for walking it by hand
node playwright/test-spa-landing/test.js        # the guest home: the sentence and its menus,
                                               # PLAY NOW against Sage and a friend, old links
                                               # redirect, a full create -> play click-through
node playwright/review-pages/test.js            # screenshots of the guest home, its menus, the
                                               # friend's dialog, the lobby and the theme picker
                                               # (desktop + phone)
node playwright/review-close/test.js            # screenshots of the two ways a room is ended:
                                               # the x on a LIVE GAMES row, END THIS GAME in
                                               # the lobby, END SESSION beside READY between
                                               # games, and the card a level session ends on
                                               # (three widths; it arranges the rooms itself)
node playwright/review-games/test.js            # screenshots of games in play (desktop + phone)
node playwright/review-bot/test.js              # screenshots of a game against Sage: the table,
                                               # a turn played, and Sage thinking about the answer
                                               # (three widths). Needs an engine -- the point is
                                               # what a real think looks like -- so start the fly
                                               # proxy first
node playwright/review-replay-mobile/test.js    # screenshots of the replay's verdict, CUBE and
                                               # overview on two phones, sideways, and a desktop
```

CI (`.github/workflows/ci.yml`) runs the same steps as `bin/check --browser`,
side by side: the suites (compile, Gleam, Elm, formatting), the Elixir
tests in four partitions, and the Playwright smokes in five shards (each its
own server and database; the matrix says which smokes each runs and what
they cost), green when all are. It runs on pull requests and on pushes to main, once per commit;
a newer push to a branch cancels the run it supersedes, a push to main is
never cancelled.

**Speed is a feature of the suite.** A check nobody runs is worse than a slow
one, so keep it under about two minutes: the Gleam tests run one worker per
core (`test/oskol_runner.erl`, replacing gleeunit's one-at-a-time list),
tooling that walks a game asks the host for `legal` rather than rendering a
whole update per step, and the few tests whose cost is waiting -- whole
matches played at random, clocks that must run out, retry backoffs -- are
tagged `@tag :slow` and left to CI. When a new test takes seconds, ask
whether it is waiting or working: waiting is tagged, working is parallel.

## Build notes

- mix and the gleam CLI share `build/`. `mix compile` removes the
  `gleam@@compile.erl` escript gleam leaves behind (see
  `Mix.Tasks.Compile.GleamClean` in mix.exs), and `bin/test-gleam` clears our
  package's gleam build output so the gleam CLI recompiles it with beams after
  mix has touched it. Use `bin/test-gleam`, not bare `gleam test`.
- Elixir test support lives in `test_support/`, not `test/support/`, because
  gleam compiles any `.ex` it finds under `test/`. `test/oskol_test_files.erl`
  is the one Erlang file under `test/`: file access for the golden tests.
  `src/oskol_json_ffi.erl` is the one under `src/`: gleam_json's Json is
  iodata on Erlang, so stored JSON text is already a Json value.
- The gleam compile step forwards positional args to deps tasks. `mix test`
  is aliased to compile first and then run with `--no-compile` so
  `mix test path/to/file.exs` works; for scripts use
  `mix run -e 'Code.eval_file("path")'`.
- In this environment the Elm package cache is populated by git clone
  (GitHub zipballs are blocked); see `.claude/skills`.
- The pixel font (Press Start 2P) and the landing sans (IBM Plex Sans) are
  self-hosted under `priv/static/fonts`; nothing loads a font from a CDN.
- Playwright scripts take the browser from `PW_CHROMIUM` when set (`bin/check`
  falls back to a preinstalled Chromium under `/opt/pw-browsers`); CI runs
  `npx playwright install chromium` instead.
