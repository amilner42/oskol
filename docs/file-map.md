# File map

What lives where, file by file. `AGENTS.md` has the short version; when you
add, move or rename a file named here, update this map in the same PR.

```
src/gamekit/        framework: rng, scene, event, action, game, clock, instance
                    (typed `Running`, and the `Instance` that erases it),
                    replay (a log folded through the typed steps),
                    registry (add games here), host (Elixir surface),
                    text (agent/test rendering), conformance, fixture
src/backgammon/     Backgammon: board (rules + move generation), state (turns,
                    dice, cube, match play), engine, projection, game,
                    analysis (the analysis engine's board, a game's turns, and
                    the one turn a step just committed), bot (Sage)
src/oskol/          the platform's own decisions, in Gleam (see
                    architecture.md): core (ctx, session,
                    error, envelope), caps (the IO a handler may do),
                    rooms (codes, names, errors, invite), guests/identity,
                    landing/copy, reviews/report, puzzles (+ puzzles/extract,
                    puzzles/picture), practice/deck (the puzzle deck),
                    handlers (rooms, landing,
                    reviews, record, ratings, auth, home)
test/gamekit/       protocol, rng, clock, action, event, golden replays
test/oskol/         handler and rule tests on stub capabilities (fakes.gleam)
test/backgammon/    board rules, engine, cube, oracle, properties, turns
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: setup, auto-start, actions, clocks, rematch
lib/oskol/game/bot.ex           a bot seat's turn: a supervised task asks the game
                                what to do and applies it, never the room
lib/oskol/persistence.ex        games + game_actions tables (seed + action log per room)
lib/oskol/guests.ex             silent guest identity: guests table (name + prefs)
lib/oskol/auth.ex               accounts: users + login_tokens, the rows a sign-in spends
lib/oskol/limiter.ex            the rate counters, sign-in mail's and the analysis
                                board's (ETS, per node; `allow/1`, `allow_mail/1`)
lib/oskol/analysis/asker.ex     the analysis board's line to the engine: jobs by
                                puzzle key, two in flight, twenty waiting, the 60 s
                                circuit, outcomes in ETS for ten minutes
lib/oskol/mail.ex               the one mail Oskol sends: the sign-in link and code
lib/oskol/mailer.ex             Swoosh: Postmark in prod, /dev/mailbox in dev
lib/oskol_web/plugs/guest_id.ex mints/renews the year-long guest cookie on every visit
lib/oskol/game/persister.ex     write-behind: rooms cast, one process writes in order
lib/oskol/game/rehydrator.ex    rebuild a room from the log on lookup (deploys, idle stops)
lib/oskol/reviews.ex            game_reviews + game_records + turn_grades tables, the
                                log a review reads, the engine's HTTP
src/oskol/core/raw.gleam        stored JSON back onto the wire without rebuilding it
lib/oskol/reviews/grader.ex     grades a turn as it is committed into turn_grades, the
                                warm cache the end-of-game job reads; answers nobody
lib/oskol/reviews/queue.ex      runs post-game reviews one room at a time, off the room,
                                deck syncs the same way ({:deck, user_id}), and one
                                batch of owed puzzle pictures a sweep (:pictures)
src/oskol/practice/sync.gleam   filling an account's mistakes deck: whose, in what
                                order, what is stamped, and when to give up
src/oskol/handlers/practice.gleam  a practice session: an account's deck, a guest's
                                own mistakes, KEEP GOING and PRACTICE ANYWAY, the
                                browser's timezone, burying one; the five decks
                                (/papi/practice/decks), a deck's page, its head
                                (`deck_head`) and the sitemap's sets (`indexed_slugs`)
src/oskol/practice/catalog.gleam  the five decks side by side: the three tiers and the
                                sets, each with its wire id and its page slug
src/oskol/practice/cost.gleam   what your mistakes cost in PR: the home's window, minus
                                their `puzzle_sources` rows by band, and minus the
                                patched ones (the `analysis.mistake_costs` cap,
                                `Oskol.Reviews.mistake_costs/1`)
src/oskol/handlers/puzzles_hub.gleam  TRY ONE: a random puzzle whose answer stands
                                clear, for a stranger on the practice home
src/oskol/practice/decks.gleam  the universal sets (openings, replies): the registry,
                                each set's retain scope, a player's standing, adding one
src/oskol/practice/openings.gleam  the 15 openings and 315 replies: positions, the
                                engine request, and when an answer is trusted
src/oskol/handlers/decks.gleam  /papi/decks: the sets on offer, a session, adding one
src/oskol/handlers/decks_build.gleam  building the sets from the engine (the operator's
                                mix oskol.decks.build): only what is missing is asked
src/oskol/caps/decks.gleam      a set's members, its write, and the practice caps over
                                a retain scope (lib/oskol/gleam/caps/decks.ex)
lib/oskol/practice.ex           those decisions run with the real rows behind them
lib/oskol/puzzles.ex            puzzles + puzzle_sources/attempts/shares/images tables;
                                the one write, in one transaction with its marker
src/oskol/analysis/setup.gleam  the position a player sets up on the analysis board:
                                the shape and its wire, check's refusals, the puzzle
                                question and engine turn it asks, flip, and the way
                                back from a stored question
src/oskol/puzzles.gleam         a puzzle's stored shape: the question, its canonical
                                key and id, the answer, the JSON of each column
src/oskol/puzzles/extract.gleam which turns of a graded game are puzzles
src/oskol/handlers/analysis.gleam POST/GET /papi/analysis: the cache by key, the
                                budgets, the refusals, and `store` (an engine answer
                                kept as an "analysis" puzzle); its controller is
                                lib/oskol_web/controllers/api/analysis_controller.ex
src/oskol/handlers/puzzles.gleam the puzzle pages: the question, the grade, the
                                 reveal, what an answer does to a deck, the
                                 memory line, a game's own mistakes
src/oskol/puzzles/tree.gleam     every legal way to play a roll, as a DAG of
                                 boards the page walks (no move generator in Elm)
src/oskol/puzzles/grade.gleam    right or a miss (0.02 lost is a miss), the band an
                                 answer fell in, and the cube answered by its side
                                 against the engine's five bands
src/oskol/puzzles/fixture.gleam  real payloads for the Elm suite (mix oskol.fixtures)
lib/oskol/puzzles/tree_cache.ex  a puzzle's tree, worked out once (ETS, bounded)
src/oskol/puzzles/picture.gleam a puzzle's link picture as SVG: the board in the
                                default theme, 1200 x 630, pure
lib/oskol/puzzles/pictures.ex   rasterises it (rsvg-convert) into puzzle_images in
                                the review job and the sweep, bounded; never on a request
lib/oskol_web/plugs/puzzle_picture.ex  GET /puzzles/:id.png from the row, or the
                                 site's board (priv/static/images/puzzle-board.png)
priv/static/images/invite-board.png  the picture an invite link unfurls with: the
                                 opening position and the invitation's words, drawn
                                 once by `Pictures.write_invite!` from
                                 `puzzles/picture.invite_svg`
lib/oskol/game/ready_up_patch.ex  one-off: old match logs get the READYs the engine now waits for
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
src/oskol/rooms/seat.gleam       who holds a seat (the guest, the account that
                                 owns it, or a bot and therefore nobody), whether
                                 it may be claimed, and what an attach means: the
                                 same client back, or a takeover
src/oskol/rooms/code.gleam       the shape of a room code, and how a typed one is read
lib/oskol_web/controllers/spa_controller.ex    "/" and "/:slug": the SPA shell
                                 plus the title, description, canonical, og
                                 and JSON-LD a crawler reads
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the same client
lib/oskol_web/controllers/removed_game_controller.ex   old /poker, /go, /chess links -> "/"
lib/oskol/gleam/ctx_builder.ex   builds the Gleam Ctx and Session for a caller
lib/oskol/gleam/caps/*.ex        the real IO behind src/oskol/caps/*.gleam
src/oskol/caps/practice.gleam    the puzzle deck: what a player is drilling, what is
                                 due now, how an attempt went, and the correction
                                 after the reveal; the grid's `cells`, today's answers
                                 by band, KEEP GOING in one band, the ladder's
                                 `intervals`. The retain library is behind it and
                                 nothing above this file knows that
lib/oskol/gleam/caps/practice.ex its real IO, over retain: times cross as Unix ms, a
                                 card's content as JSON text, tags sorted; a card is
                                 banded by the account's own sources (`owner/2`)
src/oskol/practice/deck.gleam    the deck's own rules: due before new, three new a
                                 day worst first (`new_per_day`), what counts as
                                 patched (`patched_level`, the fourth rung), the
                                 three bands each in three states (untouched, in
                                 progress, patched) with what each still has to do
                                 today, which tier to lead with (`tiers`, `lead`,
                                 `has_work`, `left`), the day as a plain count
                                 (`today`: no target, and so no quota), one tier's
                                 own queue (`band_session`), KEEP GOING
                                 (`keep_going`) and PRACTICE ANYWAY (`anyway`), a deck's
                                 standing from its cells (`standing`, `held_days`),
                                 and the sentence each
                                 refusal gives the player (a puzzle not in the deck
                                 is the only 404; a snooze needs a card in rotation)
lib/oskol_web/controllers/api/landing_controller.ex   /papi JSON for the Elm client
lib/oskol_web/controllers/api/home_controller.ex      /papi/me/home and the
                                 recent rooms it pages
src/oskol/handlers/home.gleam    the signed-in home: the live games, the two
                                 PR windows, the streak and the sentence, the
                                 deck's tiers, the recent rooms (a
                                 match folded into one entry) and their cursor
src/oskol/caps/activity.gleam    was this player here today: the local days a
                                 puzzle was answered or a game of theirs
                                 finished, which the streak is counted over
assets/src/Main.elm              SPA shell: routes, page dispatch, JOIN GAME, and the
                                 bar every page wears (`bar`: one GameLanding model
                                 for the session, `navBar` drawn over every page and
                                 `barModals` -- CREATE GAME, LIVE GAMES, SIGN IN --
                                 over whatever page is up; a full-screen page, the
                                 table, the replay, a puzzle, sizes itself to what
                                 the bar leaves, `--page-h` in app.css)
assets/src/Run.elm               a practice run, pure, kept by Main: its source (a
                                 tier, a set, one game), the strip it hands the page,
                                 asking its queue again past its ids, and the way on
                                 from the end card (KEEP GOING, PRACTICE ANYWAY); when
                                 today's set is done (`celebrate`, once a run)
assets/src/Route.elm             the client routes, mirroring the server's
                                 (`Analysis` -- /analysis?xgid=&p=)
assets/src/Api.elm               the /papi envelope + CSRF header
assets/src/Api/Catalog.elm       the landing pages' data and its decoders
assets/src/Page/GameLanding.elm  "/" the guest's home page (`home`: the site's bar,
                                 `navBar`, passed in -- the bird, the boards and ☰ --
                                 OSKOL, "Play backgammon.", the demo board, and the one
                                 sentence "Play [a single game] against [Sage] with no
                                 clock" over PLAY NOW; a friend's name dialog) and
                                 "/:slug?game=" what an invite offers. `createOnly`,
                                 `createModal` and `themePicker` are what the signed-in
                                 home starts a game and picks a board with
assets/src/Ui/Loading.elm        `/` before it knows which home it is: the bar with
                                 only the bird, and a loading bar, until /papi/me
                                 (and an account's home) answers and at least 1 s
                                 has passed; the server paints the same markup first
assets/js/demo_board.js          <oskol-demo-board>: the guest home's board, a CSS-3D
                                 board in the page's theme playing a demo game on a loop;
                                 decorative, talks to nothing, fits itself in its box
assets/src/Page/Home.elm         "/" for an account, under the site's bar (whose
                                 ☰ leads with PLAY for an account): form first (two numbers, the
                                 streak, the sentence, the line), live games with your
                                 move first, PUZZLES (one tier's card -- `Ui.Tiers` --
                                 ) and recent
                                 matches with MORE -- a line
                                 per room, a match opening in place to list its games.
                                 Everything from one answer; `Main` picks between this
                                 and the board by the session
assets/src/Api/Home.elm          /papi/me/home and /papi/me/games/graded (a room an
                                 entry, its graded games inside), and the one line a
                                 browser with no account gets
assets/src/Ui/LiveGames.elm      one row per game you can pick back up, drawn the same
                                 on both homes; the row is the whole link, so
                                 the x that ends a closable one is a button
                                 beside it, never inside it
assets/src/Page/Play.elm         "/:slug/:id" the table, and the lobby before it
                                 (END THIS GAME, for a room nobody joined);
                                 asks /puzzles?game=n for each game /ratings reports
                                 graded (a seat only) and feeds both result cards'
                                 PRACTICE THIS GAME'S N MISTAKES and save offer
assets/src/Page/Replay.elm       "/:slug/:id/replay" a room's games played again, with the
                                 engine's analysis (polls /reviews while any is pending):
                                 beside the board one panel with three tabs, OVERVIEW
                                 (each player's PR and grade counts, the mistakes list,
                                 each a door to its step; always there, and it keeps
                                 the step), MOVE (the line's verdict: a sentence in words
                                 built from the chances over the numbers in columns;
                                 greyed at the start) and CUBE (a roll's other side,
                                 greyed off a roll); a step opens MOVE, or CUBE when it
                                 cost more; the band offers the best move, the dice take
                                 the move back; a seated reader's overview says the
                                 game's mistakes are in their practice already (signed
                                 in) or "Sign in to practice these N mistakes",
                                 `Ui.SignIn` behind the words (`Out = SignedIn`); on a
                                 phone (`onePanel`: under 640 wide, or
                                 under 480 tall sideways) the panel has no scroll of its
                                 own and the page scrolls
assets/src/Page/Puzzles.elm      "/puzzles" the practice home: the five decks from
                                 /papi/practice/decks, one in front (`Ui.Deck.card`)
                                 and four rows; the streak and the day, what the
                                 mistakes cost; a guest's "23 mistakes from your 4
                                 games", a stranger's TRY ONE
assets/src/Page/Analysis.elm     "/analysis" the analysis board: the brushes, the board
                                 as `View.viewEdit` draws it (a tap, a right click, a
                                 long press per point and bar half), the settings
                                 strip, OPENING / CLEAR / FLIP, the XGID with COPY (the
                                 `copyText` port) and IMPORT, the check line and
                                 ANALYZE; the doors in (?xgid=, ?p=); the press (the
                                 plate counting seconds, the poll), the answer's panel
                                 (`#an-panel`: the best play and the candidate table, or
                                 the cube's line; a candidate on the board), SHARE /
                                 OPEN AS PUZZLE, the refusals and TRY AGAIN
assets/src/Api/Analysis.elm      POST /papi/analysis and GET /papi/analysis/:key: the
                                 status decoder, the reveal ({best, top, cube, n_legal,
                                 levels}, through the puzzle reveal's own decoders) and
                                 a refusal's `retry_after_s`
assets/src/Ui/Candidates.elm     the engine's candidate table (`.rp-top`, `data-rank`
                                 rows: move and its mark, equity, win, gam+, gam-), one
                                 renderer for the replay, the puzzle reveal and the
                                 analysis board; each page says what its rows do
assets/src/Page/Practice.elm     "/practice/<slug>" one deck's page: the card at page
                                 size, the ladder in words, what is due, the month,
                                 and for a tier what it cost
assets/src/Ui/Deck.elm           one deck as the card and as a row: the mark or name,
                                 the ring, the grid and its legend, the state line,
                                 the cost lines and the one button (`action`); `Size`
                                 (`OnHub`, `OnPage`), `open`, `squares`, `begun`
assets/src/Api/PracticeDecks.elm /papi/practice/decks and its :slug page, KEEP GOING
                                 and PRACTICE ANYWAY for a tier and a set (strict
                                 about counts)
assets/src/Ui/Charts.elm         the home's and the practice pages' pictures: the PR
                                 line, the ladder, the 30 days, the band bar, the
                                 mastery `grid`, today's `ring` and the rows' `miniRing`
assets/src/Ui/Mistakes.elm       every word practice is said in (pinned in MistakesTest)
assets/src/Ui/Tiers.elm          the home's practice section: one deck in front of you:
                                 the worst tier the player has made a mistake in, by
                                 the replay's own mark (?? ? ?!), "31 left to master" with
                                 "23 mastered" quieter beside it, its bar and TRAIN;
                                 the other tiers as quiet rows you may tap. A tier with
                                 nothing due and no new ones left today says so warmly
                                 and offers the next tier down instead; with no tier
                                 anywhere in work, one line and nothing to press
assets/src/Api/Practice.elm      /papi/practice (with `?band=`), /tz and /papi/puzzles/random
assets/src/Api/Decks.elm         /papi/decks: the sets on offer, a session, adding one
assets/src/Ui/Decks.elm          every word a set is said in ("11 left to learn · 4
                                 learned"): learned, never fixed or patched
assets/src/Page/Puzzle.elm       "/puzzles/:id" one puzzle: the question over the board
                                 (Games/Backgammon/Puzzle.elm's `Table`, the page owning
                                 the path and the lazy fetches), PLAY or the two cube
                                 buttons, the verdict line (RIGHT, or the miss by its
                                 band), the reveal in the replay's words, the level line
                                 and its four choices, which apply on tap and explain
                                 in a fixed line (NEVER alone asks: YES, NEVER), the
                                 memory line, SHARE, and -- in a run -- the strip over
                                 the board and ANOTHER / I'M DONE after every reveal;
                                 on the one that finishes today's set ANOTHER or I'M DONE brings
                                 the celebration as the next card ("Keep going?",
                                 KEEP GOING beside I'M DONE); the end of a run is
                                 the score (one is a whole session and says so), "N
                                 practiced today", the way on (KEEP GOING, PRACTICE
                                 ANYWAY) and the way back, or the sign-in for a guest
assets/src/Games/Backgammon/Puzzle.elm  the puzzle wire: the question and tree decoders,
                                 the board on a tree node, and the reveal's decoders
                                 (verdict, candidates, cube band, schedule, memory)
assets/src/Games/Backgammon/Replay.elm  the record and reviews as the replay reads them:
                                 decoders, the board at each step, verdicts per record line;
                                 the engine's cube call is read once here, into `Optimal`
                                 (no double, double/take, double/pass, or a word a later
                                 engine wrote), and its answer into `Response`
assets/src/Games/Backgammon/Setup.elm   a position set up on the analysis board: the
                                 twin of src/oskol/analysis/setup.gleam (its wire shape,
                                 `check`'s sentences), `opening`, `empty`, `flip`, a
                                 puzzle as its page shows it (`fromQuestion`), a replay
                                 step's decision (`fromReplay`, OPEN IN ANALYSIS), and the
                                 board the slab draws for it (`snapshot`)
assets/src/Games/Backgammon/Xgid.elm    eXtreme Gammon's position id in and out of a
                                 Setup, pinned by vectors (XgidTest); the field meanings,
                                 checked against gnubg, in docs/analysis.md; the server
                                 never reads one
assets/src/Games/Backgammon/Words.elm   the engine's verdict in words and numbers, pure:
                                 the move's two sentences, the cube's from either side,
                                 the three equities with the call in ink, the chance cells
                                 and grade tags, the best play on its own
                                 (`bestInWords`). The replay, the puzzle reveal and the
                                 analysis board read it; `tooGood` is the twin of Gleam's
                                 `oskol/puzzles.too_good` and moves with it
assets/src/Ui/Dialog.elm         the one dialog frame both homes open (JOIN GAME, SIGN
                                 IN, CREATE GAME, LIVE GAMES): a rounded sheet, the
                                 eyebrow heading and a plain ✕, left-aligned text
assets/src/Ui/Shell.elm          the OSKOL wordmark, the code prompt (JOIN, on both
                                 homes), the footer
assets/src/Ui/Scrub.elm          one row of plates (arrows outside, buttons between) under
                                 the table's board and the replay's, the same on both
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Backgammon/View.elm  the backgammon board (and the two
                                 player bars: name, presence dot, match PR
                                 with the account's career under it);
                                 `viewStill` draws one position, `viewPlay` the
                                 same slab with its taps switched on
assets/src/View/Clock.elm        clock display
assets/css/app.css               the multicade/notebook design system (paper, pixel,
                                 pix, btn-arcade, tile, bg-board...)
                                 plus the landing's quiet notebook (quiet, q-card,
                                 q-title, q-eyebrow, q-opt, q-btn, q-field)
                                 and the twelve backgammon boards (.bg-theme-*)
src/oskol/guests/prefs.gleam     the display preferences a guest may keep, and
                                 the values each one allows
src/oskol/handlers/auth.gleam    signing in: the mail, the link, the code, the
                                 refusals, the rate verdict, where `next` may point
lib/oskol_web/controllers/login_controller.ex  GET /login/:token: reads the token,
                                 spends nothing, serves the shell with its flags
assets/src/Page/Login.elm        that page: confirm, the win, expired (a fresh mail)
assets/src/Ui/Username.elm       a new account's username on the win, and changing it
assets/src/Ui/Identity.elm       the guest / account badge beside every name
src/oskol/guests/username.gleam  which usernames a new account tries, in order
assets/src/Ui/SignIn.elm         signing in, the one component every entry embeds:
                                 email -> "Check your email" + six digits -> the win
assets/src/Api/Auth.elm          /papi/auth/* and /papi/me for the client
playwright/test-accounts/test.js the whole sign-in flow in three browsers
playwright/test-home/test.js     the signed-in home end to end (setup.exs makes the
                                 account and its graded games)
```
