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
`handlers/puzzles.attempt_body`, and the three schedule shapes).

**Elm (`elm-test`)**
- `ProtocolTest`: every fixture payload decodes; cross-checks that hold for
  any game (viewer matches seat, spectators have no legal actions, select
  candidates exist in their zone, ids unique per zone, events only name
  tokens the viewer can see).
- `BackgammonViewTest`: the view on real scenes, pure update logic, and
  rendered DOM facts (30 checkers, sources marked only for legal moves,
  buttons follow the legal actions).
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
  as the one-tier card (its mark, what is left to fix, FIX ONE with its
  tier, the quiet rows and tapping one, "4 fixed today" with no
  denominator).
- `MistakesTest`: every word practice is said in, pinned -- the tiers by
  mark and name, "31 left to fix" and "23 patched", what a tier in good
  shape says and why, the all-clear line, the next tier's button, "3
  fixed today", and a run of one reading as a finished thing.
- `PuzzlePageTest`: the page on the generated fixtures: the reveal decodes
  (a fifth verdict word fails it), a tap walks and UNDO walks back, a lazy
  node is fetched and merged, PLAY posts exactly the path with the key (and
  waits for the key), the verdict and "you" in the table, the cube scale
  with the engine's band, the level line in its three states and after an
  override, ANOTHER and I'M DONE only from the shell (ANOTHER only where
  there is another), the memory line on 200 and not on 404; the session
  strip (the tier's mark and the day's count, no total, a mark only for
  what has been reached); the end of a run: every verdict reported, a run
  of one reading as a whole session, the card for a guest (the sign-in,
  going on to `/puzzles`) and for an account (the summary and the way
  back, and nothing to keep going with).
- `PuzzlesHubTest`: the practice home on the wire's answers -- the
  one-tier card in each of its states (a tier with work, a tier in good
  shape offering the next down, everything in good shape with nothing to
  press, an empty deck), the quiet rows and tapping one, FIX ONE as
  `StartRun` with its tier, a guest's mistakes line, a stranger's TRY ONE
  and the empty pool's sentence, and a decoder that refuses a malformed
  count rather than defaulting it.
- `ReplayTest`: the replay on the real record and analysis of seed 000011
  (`ReplayFixtures`): decoders, the board at every step, stepping, keys,
  swipes, game switching, and the analysis filling in without moving the
  viewer; polling only while something is pending.
- `WordsTest`: the verdict sentences where they are written, on made-up
  verdicts -- every move grade with its gains and costs, every cube call
  from both sides of the cube, the too-good rule the Gleam twin shares,
  and the engine's three words read into `Optimal` (a fourth falls back
  rather than being guessed at).

**Elixir (`mix test`)**
- `test/oskol/room_test.exs`: `Oskol.Bots` (test_support) plays random
  legal actions through the room for every registered game and format,
  many rooms concurrently; disconnect, rejoin, rematch keeps the setup.
  Channel tests cover join replies, spectators, per-player payloads, and
  reconnects; `spa_controller_test.exs` covers what is still the server's on
  the two landing routes — the shell, the head a crawler reads, the 404 for a
  slug that names no game, the removed games' redirects, and the guest
  cookie and the name it remembers.

**Browser (`bin/check --browser`)**: Playwright smokes create real games and
play them; review scripts take screenshots for eyeballing. The ways into a
game live once, in `playwright/lib/flows.js`: `createGame` (a guest says it
in the home's sentence and presses PLAY NOW; an account uses ☰'s PLAY
and its dialog; by element id), `barItem` (anything in ☰), `joinByLink`, `joinByCode` and
`openSeat`, and `seatedContext` for a browser that already holds a seat. A
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
node playwright/test-guest-prefill/test.js      # the site remembers a guest's name (friend dialog,
                                               # PLAY NOW against Sage)
node playwright/test-puzzles-cards/test.js      # PRACTICE THIS GAME'S N MISTAKES from both result
                                               # cards (setup.exs arranges and grades the games)
node playwright/test-landing-screenshot/test.js # Playwright itself works: one landing screenshot
node playwright/review-themes/test.js           # every board theme, shot on a phone; the pick
                                               # survives a reload
node playwright/test-backgammon-dance/test.js   # backgammon: a danced turn (it arranges the
                                               # room itself), the roll animation, the delay
node playwright/test-backgammon-landscape/test.js  # backgammon on a sideways phone: the board
                                               # fits the screen height exactly, nothing scrolls
node playwright/test-backgammon-replay/test.js  # the replay of a finished match (it arranges
                                               # the room): steps, keys, swipes, analysis
                                               # pending -> done, retry, phones; the analysis
                                               # is stubbed unless REPLAY_REAL=1
node playwright/test-puzzle/test.js             # a puzzle from a link: setup.exs arranges a game,
                                               # grades it against a Req.Test engine in its own VM
                                               # (real legal plays, the played one a mistake) and
                                               # extracts; a stranger, the opponent (memory line)
                                               # and the mistake's own player signed in (level
                                               # line, SOONER) play it; phones; the board is the
                                               # table's size
node playwright/review-puzzle/test.js           # screenshots of the puzzle page: question, staged,
                                               # reveal, a candidate, the cube scale (phone, small,
                                               # landscape, desktop)
node playwright/test-puzzles-hub/test.js        # the practice home and a run: setup.exs's game, the
                                               # first seat trimmed to 12 mistakes; a stranger's TRY
                                               # ONE, a guest's run of 12 to the score and the sign-in
                                               # ask, sign in there, the one-tier card and its
                                               # timezone sent once, FIX ONE's run of the day's 3
                                               # watching the strip, the summary and the way back,
                                               # then one mistake and I'M DONE; phones
node playwright/review-puzzles-hub/test.js      # screenshots: the hub leading with ??, ?? in good
                                               # shape with ? offered, everything in good shape, a
                                               # session mid-run, the summary after one mistake
                                               # (shape.exs's SHAPE_STATE arranges each), plus the
                                               # stranger's and guest's hub and the home's section
playwright/review-decks/run.sh                  # screenshots of the sets on /puzzles, a run
                                               # through the openings, the reveal and the end
                                               # card (four sizes); serves its own port and
                                               # database and builds the sets on a stub engine
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

CI (`.github/workflows/ci.yml`) runs the same steps as `bin/check --browser`:
two jobs side by side, the suites (compile, Gleam, Elm, Elixir, formatting)
and the Playwright smokes (one server, in `bin/check`'s order), green when
both are. It runs on pull requests and on pushes to main, once per commit;
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
