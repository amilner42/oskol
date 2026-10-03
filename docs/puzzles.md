# Puzzles and practice (backgammon)

How mistakes become puzzles, how a puzzle is graded and scheduled, the deck,
and the universal sets. Product intent: Aveline `puzzles-brief` (and its
amendments in `decisions`); the original plan and wire contract:
`puzzles-tip`, `puzzles-wire`. What the pages show: Aveline `pages`. The
spaced repetition is the `retain` library, called only from
`lib/oskol/gleam/caps/practice.ex`.

## Extraction and storage

Every mistake the engine finds becomes a puzzle: the position, the
question in the game's own words, and the answer. Written once, at the
one moment the board a decision was made *on* exists -- the review job,
with the engine's answer and the game's own turns both in memory. No read
path builds one and nothing re-asks the engine to recover one.

- **Gleam decides.** `src/oskol/puzzles/extract.gleam` says what counts: any
  decision that gave up 0.02 or more (doubtful and worse), checker or cube,
  never a forced play, a dance, or a "no double" where no double could have
  been offered (the replay's own cube rule -- the opening roll, a cube the
  mover does not hold, the Crawford game). The checker play of a turn whose
  double was taken is skipped when its answer predates the engine's fix
  (`bg-analysis-post-take-context`): that engine graded it on the pre-offer
  cube. The fix shipped with `all_results`, so "old" is read off the answer
  itself -- a move without `results` (`extract.before_results`) -- and an
  answer from the fixed engine has every such play asked -- **on the cube it
  was played on**, doubled and the opponent's (`analysis.played_on`), never
  the cube the turn began with. Until `bg-post-take-cube` the question took
  the turn's starting cube, so the puzzle showed one cube and was answered
  on another; `mix oskol.puzzles.repair_post_take`
  (`Oskol.Puzzles.PostTakeRepair`) deleted those, cards and all, and
  reopened their games for the sweep to extract again. Skipped turns are
  still written, as a source with a reason and no puzzle, so the backfill
  can count and re-ask them.
- **A puzzle is public and deduplicated.** `src/oskol/puzzles.gleam` is the
  stored shape: the question is mover-relative (the engine's 26-int board
  from the player on roll's side, the roll high die first, the cube value
  and owner, the away scores, Crawford, Jacoby; a cube question carries no
  dice), the `key` is the sha256 of its canonical one-line form, and the id
  is eight characters of the room-code alphabet read off that same digest.
  A `double` and a `take` are two questions on one position, and both store
  the same three equities -- always the *doubler's* payoff. Whose mistake it
  was is a `puzzle_sources` row, and the seat of a take is the responder's.
  **A stored answer is never rewritten**: a shared link must not change its
  mind, so a change of shape is a migration. The one audited exception: an
  answer that is not `complete` (a column, Gleam's word on it:
  `puzzle.complete` -- every legal result for a checker play, the chances
  for a cube verdict) is replaced by a complete answer to the identical
  question, in `Oskol.Puzzles.store/4`, with `answer_upgraded_at` set. The
  question is the key so it is the same puzzle, the complete answer is a
  superset, and nothing anyone was shown changes: an attempt that was
  "unknown" becomes gradable. A complete answer is never touched.
- **The answer is complete for new puzzles.** The review request asks
  `all_results`, which costs the engine nothing (it evaluates every legal
  play anyway; `top_moves` only truncates what it writes down), so the
  answer holds every legal play's board and cost plus full details for the
  top five and the move played. `complete` is `results` numbering exactly
  `n_legal`, never merely "not empty": a truncated list stored as the whole
  of it would grade a good answer wrong. A review taken before the flag says
  `complete: false`, and an attempt outside its five is honestly unknown.
- **Only the queue writes puzzles.** `settle` takes `Extracting` from the
  queue's job and `ReadOnly` from a read, so a GET anyone with the link can
  make never writes a puzzle, never spends an extraction attempt and cannot
  race the job on the same game. A read still renders an answer it finds
  unrendered and leaves the puzzles owed.
- **One transaction, one marker.** `puzzles`, `puzzle_sources` and
  `game_reviews.puzzles_extracted_at` land together (`Oskol.Puzzles.store/4`,
  behind the `puzzles` cap). Idempotent: a puzzle is written only where its
  key is new, a source only where its (game, game number, turn, kind) is,
  and a game is extracted only while it is actually owed -- so a migration
  that re-renders reports (`RerenderCubeReports`-style) cannot re-extract
  every done row.
- **Every giving-up path is charged and logged.** A failure **never fails
  the review**, but it always spends one of three `puzzles_attempts` and
  logs why -- including the case Gleam cannot even reach a decision in
  (`puzzles.failed`, for a stored answer that no longer lines up with the
  game's turns). The try that spends the last attempt sets the marker with
  `puzzles_error` beside it, so the minute sweep stops replaying that room.
  Without that, one bad row would have the sweep replaying its whole log
  every minute for ever, silently. A puzzle whose every candidate id is
  taken is skipped with `skipped_reason: "id_exhausted"`, never fatal to
  the rest of the game.
- **Nothing old is owed.** The migration marks every review that already
  existed, because the boot sweep would otherwise backfill all of
  production at deploy, ahead of live games and out of answers written
  before `all_results`. Backfilling old rooms is the operator's
  **`mix oskol.puzzles.backfill`** (`Oskol.Release.puzzles_backfill/1` from
  a release; dry run unless `--write`; `--room`, `--limit`, `--reset`;
  the queue off for the run), the one sanctioned re-ask: every decision in
  `src/oskol/handlers/backfill.gleam`, the walk and the counts in
  `Oskol.Puzzles.Backfill`. It finds an old row by its stored response (a
  turn whose `move` carries no `results`, `backfill.old_contract`), never
  by the marker; asks the engine again at the row's own levels with
  `all_results`, through the same request builder, replay and render a
  fresh review uses; checks the fresh answer before trusting it
  (`backfill.trusted`: a result per legal play, a board on every
  candidate, chances on every cube verdict -- an answer that falls short
  is quarantined: not stored, the row charged to the limit with the reason
  in `error`, named in the counts); then writes the fresh answer and page
  over the old with the game's puzzles reopened in the same transaction
  (`analysis.replace` -> `Reviews.replace/8` + `Puzzles.reopen/2`: marker
  cleared, `post_take_cube` sources dropped -- one write, so the live
  sweep never finds an old answer owed puzzles), and extracts through
  `reviews.extracted`, which writes the new puzzles and upgrades the old
  incomplete ones. An engine failure charges one attempt
  on the `done` row (`analysis.charge`: attempts and `error` only, the page
  untouched) and the run goes on; three spent and the game waits for
  `--reset`. Decks are synced at the end. A second run finds nothing and
  writes nothing. For the same reason, a future path that re-analyses a
  game that is already `done` must clear `puzzles_extracted_at` itself:
  `Reviews.save/8`'s upsert deliberately leaves it alone, which is right
  for the other rewriter (a retry of a `failed` row, which never had
  puzzles).
- **The page never knows a rule.** `GET /papi/puzzles/:id` carries the whole
  turn as a DAG (`src/oskol/puzzles/tree.gleam`): nodes are positions, so
  every order of the same checkers on a double is one node, and a node's
  children are exactly the taps the rulebook allows next (must use both, the
  larger die at the roll). `terminal` is where PLAY is offered and nowhere
  else. Built by memoising "how many dice can still be played" on (board,
  dice left) -- asking `board.sequences` per node would redo the exponential
  walk once per node. A take is turned around before it is shown
  (`handlers/puzzles.shown`): it is stored from the doubler's side and asked
  of the responder, and whoever is being asked is White at the bottom.
- **The tree has a gate.** 100 KB on the wire, 100 ms to build; the build
  gives up at 260 examined positions (61-75 ms; 400 costs 120 ms) and the
  byte budget has the last word. Measured over 4,200 position/roll pairs
  from real random play: median 28 nodes / 9.5 KB / 6.7 ms, p99 350 / 142 KB
  / 173 ms, worst 539 / 220 KB / 728 ms. About one position in forty is over
  the byte budget, all of them small doubles in contact-rich middlegames.
- **A turn too big to send whole is built once and walked.** It answers
  `tree: {root, nodes: {root only}, lazy: true}` (985 bytes on the worst
  position there is) and the page asks for each level from
  `GET /papi/puzzles/:id/tree?node=`. **A node is named by the id that
  build gave it**, never by a description of itself: an id this puzzle does
  not hold is a 404, so nothing a caller sends can put the server to work
  on a position of their choosing, and there is nothing to sign. The tree
  is kept whole (`Oskol.Puzzles.TreeCache`, twenty entries), so a level is
  a lookup -- 14 ms on the contrived worst case, against 548 ms to build it
  the once. The encoded payloads are kept too, per puzzle id, in the same
  bounded table: both are pure functions of a question that is never
  rewritten, so a hit is always right and forgetting costs a rebuild.
- **One grading rule, one place** (`src/oskol/puzzles/grade.gleam`), shared by
  the guest on a shared link and the account whose ladder is watching. A
  checker play is graded by the board it leaves, never its notation: under
  0.02 passes and 0.02 or more misses (no "close": a `?!` answer is a
  mistake, the thing the dubious tier is made of), and a board the stored
  answer has no result for is `unknown` -- old five-candidate rows -- so
  nobody is told they were wrong on evidence we do not have. A cube question
  is answered with a side, as at the table (double or not, take or pass); the
  engine's verdict is finer: the doubler's margin is `min(DT, DP) - ND`, the
  responder's is `DP - DT` (positive means take, because the responder picks
  whatever pays the doubler less), bands at 0.08 and 0.02 either side of
  zero. The right side passes, the wrong side misses, and when the engine's
  band is zero (too close to call, under 0.02 either way: about the 4-ply
  cube equities' own error) either side passes, costs nothing and reads
  "best" -- the same verdict, mark and words whichever was picked. Outside
  band 0, what the wrong side gave up is the margin itself
  (`grade.cube_cost`). **The call itself** (no double, double/take,
  double/pass, too good) is read off the same three equities, never off
  the engine's `optimal_action` label: double iff `min(DT, DP) > ND`, take
  iff `DT <= DP`, too good iff `ND > DP` (`puzzles.cube_call`,
  `puzzles.too_good`; the Elm twin `Replay.cubeCall` is held to it by
  `CubeCallTest` on fixtures the server writes). The stored answer's
  `optimal` and `too_good` are that rule's. The reveal carries `band`
  (`grade.band_name`: best, ok, doubtful, bad, very_bad, unknown) and `cost`
  beside the verdict, and shows the engine's pick among the three equities
  and the chances, nothing more. `hold` is legacy: grading no longer produces
  it, cards keep their levels and the stored partial reviews stand, and a
  stored `hold` attempt still answers `hold` when its key is retried.
- **Every finished game is the moment** (Aveline `decisions`, 2026-09-22). Both result cards at the table --
  the game-over card and the between-games card of a match or of
  unlimited play -- offer PRACTICE THIS GAME'S N MISTAKES
  (`practice-game`; "1 MISTAKE"; a quiet "No mistakes in this game" for
  none) once the game's review is done, and the replay's OVERVIEW has
  nothing to press: signed in, a line says the game's mistakes are in
  their practice already; a guest reads "Sign in to practice these N
  mistakes", `Ui.SignIn` behind the first words (`rp-deck`,
  `rp-deck-signin-open`). `Page/Play.elm`
  asks `/puzzles?game=n` for each game `/ratings` lists as graded, for a
  seat only (a spectator would be told 404), and the replay asks for the
  game being read as it switches; the cards keep the ids and hand them
  to Main as `StartRun`, the replay keeps the count. The puzzles are written a moment
  after the grade, so the endpoint answers 409 `puzzles_pending` until
  they are, and the page asks again (3 s apart, twenty times at most).
  The run ends on the puzzle page's own screen, a guest's sign-in going
  back to the table (or the replay) it was pressed at. The between-games
  card also makes the save offer, so unlimited play -- most games here --
  asks a guest to sign in after every game, not only at a match's end.
- **One scheduled answer per opportunity.** A signed-in caller whose deck
  holds the puzzle writes a `puzzle_attempts` row first, keyed by the id the
  client minted; the ladder moves only when that row is new *and* the card is
  due. A review always pushes the due date out, so a second tab or a retry
  reveals and changes nothing. A miss is `Again` (back to level 0, tomorrow);
  an `unknown` schedules nothing and defers the card to tomorrow with
  `self_grade: true`.
  **Whether an answer counts is read-then-act**, so the whole decision --
  writing the attempt row, reading the card, moving it -- runs under a
  transaction-scoped advisory lock on (account, puzzle)
  (`Oskol.Puzzles.serialize/3`). Without it four tabs at one due card wrote
  four reviews and took a level-0 card to level 4.
  **An idempotency key means something only inside one account**: the unique
  index is (puzzle_id, user_id, idempotency_key) and every read is scoped
  the same way, or somebody else's key would reach their row.
  The override (`.../attempts/:key/outcome`) **replaces** the review it named
  rather than stacking on it, so a pass then SOONER lands at level 0 once.
  Where there was no review it writes the first one, but only where the
  answer actually offered that (`self_grade`) -- never merely because none
  was written, or an answer that never had an opportunity would invent one.
  GOT IT on an answer nothing checked holds the level rather than raising
  it; GOT IT on an answer graded a miss is a 422 ("That one was a miss, so
  GOT IT is not one of its choices."). An answer at a card that is not due
  yet is a reveal and nothing else: it writes the attempt and moves nothing.
  Every schedule carries `held_days`, how long a card waits at
  `level_after` (`deck.held_days` over the `practice.intervals` cap), so the
  page says what a choice would do without a copy of the ladder. NEVER suspends the card without touching the attempt's own schedule,
  so a retry of that answer is still the same reply, and nothing can be
  overridden after it (409).
- **Share with my mistake** (`src/oskol/handlers/shares.gleam`). After the
  reveal, the seat that made the mistake -- and only it: the source's own
  `player_id`, held by the holder rule, so a guest by its cookie and an
  account from any browser it is signed in on, never the opponent, never a
  stranger (403, one sentence) -- may `POST /papi/puzzles/:id/shares` and
  get a story link, `/puzzles/:id?s=<token>`. The row is `puzzle_shares`:
  a twelve-character token of the room-code alphabet (`ids.share_token`,
  two game codes), the puzzle, the source, `shared_by` (the account id for
  an owned seat, the guest id for an unowned one) and `shared_name`, the
  sharer's display name **frozen at the mint** (a rename or a seat taken
  over must not change who the story names). One row per (source,
  sharer): `Oskol.Puzzles.mint_share/5` inserts against that unique index
  `on_conflict: :nothing` and reads back the token that stands, so two
  tabs pressing together get one link. The token is nothing but a token:
  `?s=` changes the head's title (`shares.headline`: "Arie got this wrong.
  What's your play?" / "Double to 2?" / "Redouble to 4?"; a take keeps the
  whole prompt, "Arie got this wrong. Black redoubles to 4. Take?") and puts `story` on the
  reader's own attempt's answer (`shares.story_json`, with `line`: "Arie
  played 24/23 13/11 (a bad move) and lost 2 points." -- a cube source
  reads "didn't double" / "doubled" / "took" / "passed", "a bad
  decision"); the GET, the picture and the canonical ignore it, and a
  token nobody minted or minted for another puzzle is silently the plain
  page. The page (`Page/Puzzle.elm`) shows the second button only when
  `/mine` answered `who: "you"`, sends `s` on the attempt, and renders
  `story.line` under the memory line. The result comes from the game's
  record (`puzzles/game_over`, the same reading the memory line uses).
  `puzzle_images` is the board picture, below.
- **A puzzle has a picture, drawn once, never on a request.**
  `src/oskol/puzzles/picture.gleam` draws the position as SVG, 1200 x 630,
  in the default theme's colours (`.bg-theme-midnight`, as constants), from
  the solver's side exactly as `prompt` speaks (a take is `flip`ped, cube
  owner and scores with it): the board with the mover as White at the
  bottom, stacks with a count over five, bar and trays, the dice for a
  move, the cube at its owner's side (for a take, the double on offer:
  turned to the new value on the solver's side), the score line, the
  prompt. A picture stored before the prompt named its stakes keeps its
  old words until it is drawn again. Text is
  SVG text in a system font stack; nothing loads. `Oskol.Puzzles.Pictures`
  rasterises it with `rsvg-convert` (`config :oskol, :rsvg`; the release
  image installs `librsvg2-bin` and `fonts-dejavu-core`; the SVG rides in
  as an environment string through `sh` because a port cannot close stdin
  alone) and stores the PNG in `puzzle_images` (about 90 KB: cairo's PNG
  writer, no compression flag). Drawn in the review job right after
  `store` succeeds (`puzzles.pictures` cap, `render_game/2`) and by the
  queue's minute sweep for whatever that missed (`render_owed/1`, a
  `:pictures` job, twenty a batch). Every try is charged to
  `puzzle_images.attempts` first; the third failure writes `error` and the
  sweep lets the row go until `Pictures.reset_attempts/0`. A missing
  binary is logged and charged to nobody, so a deploy without it cannot
  burn every puzzle's budget. `GET /puzzles/:id.png`
  (`OskolWeb.Plugs.PuzzlePicture`, an endpoint plug beside `Plug.Static`:
  no session, no guest cookie, no router -- and the router's grammar has
  no `:id.png`) serves the row `public, max-age=31536000, immutable` with
  an ETag, or the site's board (`priv/static/images/puzzle-board.png`,
  committed, regenerated by `Pictures.write_default!/0`) at `max-age=300`
  while a puzzle has none; an id that names no puzzle is a 404; `?s=` is
  ignored. The root layout's `<.share_card image={assigns[:share_image]}>`
  emits `og:image`, its width and height, `twitter:card`
  `summary_large_image` and `twitter:image` when a page sets
  `:share_image` to the picture's absolute URL (the puzzle page; an open
  invite, with `priv/static/images/invite-board.png`), and byte for byte
  the old `summary` tag when it does not. Tests stub the binary
  (`test_support/fake_rsvg_convert`) and run the real one only when the
  machine has it.
- Measured on the seeded match 821900 (12 games): 125 puzzles, 127 sources
  (103 move, 19 double, 3 take; 2 skipped post-take), mean stored row 1.7 KB.
  With every legal result the answer column goes from a mean of 2.4 KB to
  4.2 KB (max 17 KB, a 177-play double).

## The deck

**The deck fills itself.** An account's mistakes become cards in its deck
with nobody pressing anything: `src/oskol/practice/sync.gleam` (`sync_deck`)
reads the sources on the seats that account owns and no deck holds yet,
enrols them (`deck.enroll` -> retain, tags `{deck: "mistakes", kind}`,
content the stored question, position **worst first and the newest game
first within a band**) and stamps `puzzle_sources.deck_synced_at`. A
position is `sync.position_of(grade, ended_ms)`: a band's block of a
hundred million plus time counted backwards in minutes from 2020, which
is what fits three bands and sixty years into the 32-bit column. A card
reached in two games takes the worse of them. `mix
oskol.puzzles.reposition` (dry run unless `--write`,
`Oskol.Release.reposition_puzzles/1` the release twin) puts every card
where today's rule would: a no-op the second time, and it touches nothing but
`position`. The holder rule decides whose a mistake is,
as everywhere: the query narrows by an id, `rooms/seat.holder` answers.
Three callers, all off every hot path: the review job, where a game's
`store` has just succeeded (`sync_game`, in `handlers/reviews`); the sign-in
stamp, cast to the review queue from the **persister's own handler** once
its transaction has committed, so a caller that already timed out
(`stamp_seats/3` answers `:pending`) still leaves a full deck; and the
queue's minute sweep, for anything the first two missed.
`mix oskol.puzzles.sync` is that sweep by hand (dry run unless `--write`,
which writes nothing and charges nothing; `--reset` reopens the rows that
gave up; `Oskol.Release.puzzles_sync/1` is the release twin, and both turn
the queue off first so the boot sweep does not charge the same rows beside
them). A deck job is `{:deck, user_id}` in the same queue as a room's
review, collapsible because it syncs everything that account is owed, and
the minute scan runs in a task rather than in the queue process.

**Bounded, and never silent.** Idempotent at both levels; reading an
account's sources charges one of three `deck_attempts`; and a try that
fails — *including* retain raising, which is the failure that actually
happens — writes `deck_error` on the rows and leaves them out of the sweep
until an operator reopens them. A `DeckUnavailable` refusal is how an
exception crosses the cap boundary instead of being logged and lost.

**What the queries are keyed on.** `puzzle_sources.owner_user_id` is the
account whose seat made the mistake, written from `games.players[seat]` in
the same transaction as the sources and again in every write that can
hand a seat to an account -- a sign-in stamping that game's seats, and a
room writing its seat list (a join, a signed-in claim, a start:
`Persistence.update_players/2`) -- with the room's row locked so neither
side can commit past the other (`Oskol.Puzzles.refresh_owners/1`). A room
left behind before that (`puzzles-stale-owner`: a signed-in claim used to
skip it) is put right by `mix oskol.puzzles.refresh_owners`, which also
syncs the decks it affects (dry run unless `--write`;
`Oskol.Release.refresh_owners/1` the release twin). It is an index key, never
an authority: `seat.holder` still decides, in Gleam, of every row handed
back. Without it the sweep's question is a lateral join over every unsynced
row every minute, and since a guest's mistakes are never synced that set
grows for ever. `ended_ms` is the game's **review row**, not the source's:
newest game played first, so a backfill or a retried review cannot put an
old game at the front; within one game, turn order. A card's position is
seconds *back* from 2020, not negated Unix time: retain's `position` is a
32-bit column.

**A card is banded by the account's own sources.** A card's tier is the
worst grade among the `puzzle_sources` rows **this account** owns for its
puzzle (`owner_user_id`, in the mistakes scope only), never every account's:
a position is shared, and somebody else's very bad move must not put this
player's dubious one in their `??` tier. In a set's scope no row matches and
every card bands `""`. `severity`, `band_queue` (through `in_band`), `cells`
and `answered_today_by_band` in `lib/oskol/gleam/caps/practice.ex` all join
through the one `owner/2`, so the four cannot band one card two ways.

**A mistake you make again comes back.** When a sync finds a puzzle the
deck already holds, that is the player making it again in a real game, so
the card takes an `:again` (back to level 0) with a note saying which game
— but only a card **in rotation**: one never shown is already at the front
of the queue, and a suspended one the player said NEVER to, which a game
they happened to play must not undo.

## A practice session

**`GET /papi/practice`** is one page for three callers
(`src/oskol/handlers/practice.gleam`). Signed in: the deck, everything due
before anything new (`new: :after_reviews`), twenty at a time,
`counts: {due, new_today, deck}`, `today: {done}` -- a plain count of the
day's answers, on the `practice.day` cap, counted in the deck's own
timezone by exactly what the 30-day strip counts as practice -- `severity`,
the mistakes by band in their three states (untouched, in progress,
patched) with what each still has to do today (`due` now, `new_left`
capped at the day's budget of new mistakes), and `lead`, the worst band
with work (`practice.severity`, which takes `deck.patched_level` and never
decides it; `deck.tiers` folds in the budget and `deck.lead` chooses).
`?band=` narrows the puzzles to one tier (`practice.band_queue`, the same
orderings `Retain.due` and its new-card query use, with the
`puzzle_sources` join in front): due first, then ones never seen, worst
first inside the band, and never the whole deck for a band that is not
one of the three. A guest: the mistakes on the seats their cookie holds
and no account owns, newest game first, unscheduled, `counts: null`, and
**nothing written** -- only an account has a deck; their `?band=` narrows
those mistakes to that tier (each banded by the worst grade any of their
games reached it at). Nobody: an empty list, not an error. Reading never
starts a card or spends a day's budget.

**KEEP GOING and PRACTICE ANYWAY.** Once today's set is done there is
always a way on. `POST /papi/practice/more {band}` (`deck.keep_going`)
starts the deck's pace again (`deck.keep_going_new`, which is
`new_per_day`: three) of mistakes never shown, of that band
(`practice.start_new_in_band`) or of the whole deck (`""`), over the day's
budget -- the budget is the pace for the player who did not ask -- and
answers that tier's session; for a guest it is the session and nothing
else. `?all=1` is PRACTICE ANYWAY: only when the ordinary queue is empty,
the cards in rotation soonest due first (`deck.anyway`, off the `cells`
cap), each `due: false`; an answer at one is early and moves nothing
(`?all` is ignored while the queue has anything in it). `&from=<n>` skips
the first `n` of that rotation, so a run goes on past its first twenty. A
set has the same two through `POST /papi/decks/:id/more` (the set's own
pace; an account that added it, 409 `sign_in` / `not_joined` otherwise)
and `GET /papi/decks/:id?all=1&from=`.

**A session is never paged.** Every fetch is the front of the queue and
`cursor` is always null. The due set is live -- answering a card takes it
out -- so a second page at an offset would skip exactly as many cards as the
player had just answered: 21 due would end after 20 with one unseen and the
day's new cards never offered at all. A run whose ids run out asks the
front again (see below); "done for today" is a fetch that comes back with
nothing the run has not already put in front of the player.

## The five decks

What a player practices is five decks, in one shape
(`src/oskol/practice/catalog.gleam`): the three tiers of their own
mistakes, worst first (`very_bad` / `very-bad` ??, `bad` / `bad` ?,
`doubtful` / `dubious` ?!), and the universal sets from the registry
(`openings`, `opening_replies` / `opening-replies`). Each has an `id` the
wire speaks and a `slug` its page lives at (`/practice/<slug>`). A tier is a
band of the one mistakes learner, never a scope of its own: the three share
a ladder, a day and a budget. An account's own sets follow the five ([Own sets](#own-sets)).

- **`GET /papi/practice/decks`** (`practice.decks_json`) is the hub's one
  answer: `{decks, lead, today, streak, patched_level, cost_all,
  mistakes}`. Each deck is `{id, slug, kind (mistakes|set|own), name, mark,
  blurb, size, pace, joined, standing, cost}`. `standing` (an account's;
  null otherwise) is counted from the deck's cells by `deck.standing`:
  `{total, untouched, in_progress, patched, due, new_left, done_today,
  target_today, levels}`, where `target_today` is done + due + the new ones
  the day still allows -- the ring is `done_today / target_today`, which
  grows when KEEP GOING adds and is full when the deck asks nothing more
  today. `pace` is what KEEP GOING adds (the mistakes' three, a set's own
  `new_per_day`). `lead` is the worst tier with work, else a set the
  account added with work, else the worst tier with anything in it, else
  null; a guest's is their worst tier. `today: {done}` is every deck's
  answers today (the mistakes' day once, plus each set's); `streak` is the
  home's (`home.days_running`). `mistakes: {puzzles, games}` is a guest's
  ("23 mistakes from your 4 games"), null for anybody else. A set with
  nothing built is not listed. Reading writes nothing.
- **`GET /papi/practice/decks/:slug`** (`practice.deck_page_json`) is one
  deck's page: `{deck, cells, days, patched_level}`, `cells` the account's
  cards in the order the deck introduces them (`{id, level, due, status,
  position, band}`, the `practice.cells` cap), `days` the last thirty
  (`practice.days`; a tier's month is the mistakes' month). An unknown slug,
  and a set nobody has built, is a 404.
- **The cells.** Four caps added for this (`src/oskol/caps/practice.gleam`,
  the tuple order in `lib/oskol/gleam/caps/practice.ex`): `cells` (every
  card, banded by the account's own sources), `answered_today_by_band`
  (today's answers by the band of the card, adding up to `day.answered`),
  `start_new_in_band` (KEEP GOING for one tier) and `intervals` (the
  ladder, `config :retain, intervals`).
- **What the mistakes cost** (`src/oskol/practice/cost.gleam`). Each tier
  carries `cost: {games, lost, lost_patched, pr, pr_without, pr_patched}`
  and the answer `cost_all: {pr, pr_without, pr_patched}`: the rating as
  it is, as it would be without that band's mistakes, and without the
  patched ones. Decision-weighted like the home's PR, over the same window
  (`home.counted` over `analysis.graded_for`, so `pr` is the career number
  beside a name), minus the equity of `puzzle_sources` rows read by the
  analysis cap `mistake_costs` (`Oskol.Reviews.mistake_costs/1`). Those
  rows are reached **through the account's seats** (the `graded_for`
  containment), not `owner_user_id`, so both sides of the subtraction are
  the same games; the holder rule in Gleam confirms each seat. A row counts
  in the band it was graded in, not its puzzle's worst; a mistake in a game
  outside the window is dropped. Patched is the rung on a card still in
  rotation (NEVER is not fixed). Null for a guest, a stranger, a set and an
  account under three graded games (`home.min_games`). Rows only: no
  engine time, no log, no write.
- **The heads** (`practice.deck_head`, served by `SpaController.practice`).
  A set is the same page for everyone: "Openings · Practice", its blurb,
  a canonical, and in the sitemap (`practice.indexed_slugs`). A tier is
  somebody's own mistakes: "Very bad moves · Practice", `noindex`, never in
  the sitemap. `practice` is a reserved word before `/:slug`; a bare
  `/practice` is a 404.

## The pages (client wiring)

What a player sees on these pages, and in which words, is the Aveline doc
`pages`. The wiring:

**The puzzle page** (`/puzzles/:id`, `assets/src/Page/Puzzle.elm`) fetches the
question and nothing else until PLAY: the answer is not in that response,
and `/mine` is asked only after the attempt, so a page open on a shared
link can put nothing within reach. The board is the table's own
(`Games/Backgammon/Puzzle.elm` on `View.viewPlay`; a lazy tree's levels
are fetched as the path reaches them), UNDO and PLAY are its own band; a
cube question is answered in the same band with the live table's own
buttons and words (`View.viewCubeAsk`, `View.cubeAnswers`): DOUBLE / ROLL
on roll (ROLL is no double), TAKE / DROP when doubled, one word each (the
cube on offer is drawn at 4); DOUBLE, TAKE and DROP are held, not tapped,
as at the table (`View.stepHold`, the page keeping the `Hold`). TAKE and
DOUBLE send band +1, DROP and ROLL -1. Nothing answers under the board.
The question names its stakes (`oskol/puzzles.prompt`): "White to play.
Double to 2?", "White to play. Redouble to 4?", "Black doubles to 2.
Take?", "Black redoubles to 4. Take?" -- the stored cube is the one before
the offer, so the offer is twice it, a redouble when the doubler already
owns it. The score line under it (`Words.cubeBefore`, the twin of
`analysis/setup.situation`'s cube) never reads as those stakes on a take:
"cube 2, Black's, redoubled to 4", "cube centered, doubled to 2". A
take's board draws the double on offer as the table does: the cube turned
to the new value and pushed to the taker's side (`offer`, so
`View.viewCube`'s pending slot); a double's cube stays where it is. Once
answered the band keeps both buttons, the other faded (`.cube-chose-*`)
and neither live (`.cube-locked`), and the row under the board (SHARE,
SAVE, ANALYSIS, ANOTHER) is drawn and held unseen from the first frame
(`.pz-actions.is-held`), so nothing moves when the reveal arrives. The reveal opens on the verdict line (`#pz-verdict`): RIGHT ("That
is the play." / "Within 0.02 of the best. Not a mistake." / on a cube
in band 0, "Too close to call: either answer is right."), or a miss by its
band in the replay's mark and colour (?! DUBIOUS, ? BAD, ?? VERY BAD) with
"Gives up 0.04 — a dubious mistake, so it comes back." (no "so it comes
back" without a schedule). The sentence names the badge's own band
(`Words.aMistake`: dubious, bad, very bad), as the replay's cube verdict
does, so the two never disagree. Then the replay's words and table (`Words`, with
`doubleWhy`/`noDoubleWhy`/`answerWhy` for a position nobody has acted on
yet; inside 0.02 they say "Too close to call: doubling gains just 0.003,
so either is fine. If doubled, Black takes." or, for a take, "Too close to
call: passing gains just 0.010, so either is fine.") with "you" marked (a play outside the five the engine described is
the row "your play", which needs no badge) and a candidate tappable onto
the board; the cube's
scale marks the engine's band over `cubeLine`. The attempt's key is minted
once per page load (`elm/random`) and a PLAY that lands before it waits for
it, so a retry is the same answer. Signed in with a `schedule`, the level
line ("Level 2 → 3 · back in 7 days"; "back tomorrow"; an early answer
"Not due until 9 Oct — practice only, nothing moves."; KNEW IT "Marked as
known — back in a year") and SOONER / GOT IT / KNEW IT / NEVER. The graded
one is filled when `amendable`. SOONER, GOT IT and KNEW IT **apply on tap**
(since 2026-10-01; before, a tap only selected and APPLY sent it): the tap
POSTs `/attempts/:key/outcome` at once, the choice is drawn in force
(`applying`, pressed in, the four disabled until the answer lands, so
nothing is sent twice) and `#pz-outcome-why` says what it does, in one
fixed line; a tap of another replaces it (the server replaces the review
an override names, it never stacks); a tap of the one in force sends
nothing. A refusal says why in that line (`#pz-outcome-error`) and the
choice before the tap stands. **NEVER alone asks first**, because it
cannot be undone: its tap rings it (`confirmingNever`), explains, and
lays out `#pz-never-yes` ("YES, NEVER"), which sends it; any other tap
takes the question back, and ANOTHER / I'M DONE drop an unconfirmed one.
GOT IT after a miss is `aria-disabled` in its column ("You missed this
one."). Once NEVER is applied the four stay, disabled, under "Set aside".
The reveal's height is fixed across taps (the confirm's slot is always
laid out; `review-verdict/outcomes.js` and `test-puzzle` measure it). A schedule carries `patched`, true
when that answer took the mistake to `deck.patched_level` from below (the
level line then reads "Mastered. Four right in a row — back in 21 days",
`.pz-level.is-patched`). SHARE is the table's `shareInvite` port on the
clean URL. Beside it, on every puzzle, ANALYSIS (`#pz-analysis`, the
new-tab mark after it; "Open in analysis" to a screen reader) is a link to
`/analysis?p=<id>` in a new tab: the analysis board on the position as this
page shows it (`docs/analysis.md`). SHARE, SAVE and ANALYSIS are fixed boxes
on one row at every width down to 320 (`.pz-act-*`), so SHARE's "Copied" or
"Copy failed" moves nothing.

**A run is the shell's** (`assets/src/Run.elm`, pure, kept by `Main` across
`pushUrl`s because every page is rebuilt on one). `Run.Run` is `{ids, at,
answers, next, source, anyway, served, deckToday, slug, celebrated, gen}`: `source` is
`Band` (a tier: `/papi/practice?band=`), `InSet` (a set: `/papi/decks/:id`)
or `Fixed` (one game's mistakes, which ends at its last); `next` is the page
the run was started from (the hub, a deck's page, the table, the replay) and
where a guest who signs in at the end goes on to; `deckToday` is the deck's
ring and `slug` its page (where its cells are read). The hub and a deck's
page start one with `StartRun ids today tier Begun` or `StartDeckRun ids
today named Begun` (`Begun` is `{deckToday, anyway, slug}`, `Ui.Deck.begun`); a result card and the home with `StartRun`.
**A run never runs out**: the ids are the front of a queue, so past the last
one the shell asks the same queue again (`Run.refetch`, through PRACTICE
ANYWAY `?all=1&from=<served>`) and goes on with what it has not shown; only
an answer with nothing new in it ends today's set. The page is told
`hasNext` (`Run.goesOn`: always, in a run through a deck) and `progress =
{at, marks, ring, anyway}`, and draws the strip over the board
(`#pz-progress`): the tier's mark or the set's name, the deck's ring with
"3/5" beside it, an 18px tile per answer in one row that scrolls sideways
(opening at its newest end), and one reserved line under it -- the day's
count ("3 practiced today"), or "Practice only" in a run of early answers --
with, for a mistake, the `/why` line. It offers ANOTHER (`#pz-next`,
`WantsNext`) and I'M DONE (`#pz-done`, `WantsEnd`) after every reveal --
on the one that finishes today's set both bring the celebration first (below)
-- and reports every reveal and override as `Out = Answered {verdict,
schedule, grade}`, or, where ANOTHER / I'M DONE was pressed while a
choice was still on its way, `Out = AnsweredThen answer (WantsNext |
WantsEnd)`: the page waits for it, Main keeps the answer, then goes on
(`Main.puzzleOut`). An answer counts toward the day
and the ring only the first time, only when it moved something
(`Page.Puzzle.countsToday`), never in PRACTICE ANYWAY. `WantsEnd` is
answered with `Page.Puzzle.endRun {right, total} answers next`: a pass is
right, anything else is not, and `total` is **how many were answered**. The
end card (`#pz-end`) then asks where the deck stands (`/papi/practice/decks`)
for the way on (`Run.way`): `Continue` (work left today) and `MoreNew n`
(today's set done, some never shown) are KEEP GOING, `Anyway` (everything
started, nothing due) is PRACTICE ANYWAY, `NoWay` nothing; pressed, it is
`Out = GoOn way` and the shell runs on (`Run.keepGoing` grows the ring's
target by what it started). Under it the way back to `next` in its own
words ("Back to puzzles →", "Back to very bad moves →", "Back to the
game →"). The page's other `Out`s: `SignedIn (Maybe User)`, `Go path`.

**Today's set done.** When a counted answer brings the deck's ring to its
target (`done == target > 0`), `Run.celebrate` says so once a run
(`celebrated`); never for a guest (no day), PRACTICE ANYWAY or one game's
mistakes. Main calls `Page.Puzzle.celebrate`, reads the deck once by the
run's `slug` (`GET /papi/practice/decks/:slug`) and hands the page the
cells and the way on (`Run.way`). **The card is the next card** (since
2026-10-01; it used to sit under the reveal, where it was missed): the
reveal of that answer is an ordinary one (its choices still apply) whose
band offers ANOTHER -- even past the run's last id -- and I'M DONE.
Either (`Celebration.shown`; I'M DONE too, since that is when a player stops) puts the card (`#pz-today-done`) where the
next puzzle would be, on the same URL, the board and reveal gone, one
centered column at every size (`.pz-page.is-card`): the ring at 104px
filling to a check, "Today's 5 done.", what this run moved (from its own
schedules), the deck's grid with the squares this run stepped up
(`Ui.Charts.gridStepping`), for a tier what mastering won back ("Mastered
so far: 0.6 PR won back."), then "Keep going?" (`#pz-today-ask`) over KEEP
GOING (or PRACTICE ANYWAY) beside I'M DONE in one fixed band. KEEP GOING is
`GoOn way` (the `/more` path; the run goes on to its next puzzle); I'M
DONE is the end card. The card is laid out hidden until the deck is read
(or 1.5 s pass); once it is both read and shown, the `celebrateCard` port
puts the page at its top and `celebrationInView` starts the motion (about
1.7 s); `data-settled="true"` marks the last keyframe. Motion is CSS only,
under `prefers-reduced-motion: no-preference`; with reduced motion the
final state is drawn and settled at once. On desktop (1024px and up) the column beside the board is
size-contained (`.pz-page .rp-side { contain: size }`): always the board's
height, scrolling inside, so a tall reveal never stretches the board's
box.

**The practice home** (`/puzzles`, `assets/src/Page/Puzzles.elm`) is the
five decks on `GET /papi/practice/decks`'s one answer, as drawers in their
own fixed order (very bad, bad, dubious, Openings, Opening replies). One
is open, drawn as its card (`Ui.Deck.card`, `OnHub`) in its own slot: the
server's `lead`, the one tapped, or for an account with nothing of its own
the first set; a stranger has none open until they tap one. The others are
rows (`Ui.Deck.row`, buttons with `aria-expanded`); tapping one opens it in
place and closes the open one. **Nothing ever changes order.** Every row
and card starts with the deck's icon: a tier's mark in the replay's colour
for its grade (`Mistakes.markClass`, the `--g-*` tokens behind `.g-*`; the
same on a deck's page and a run's strip), a set's dice on paper. The card
is the icon and name, OPEN (to the deck's page), today's ring (`Ui.Charts.ring`), the mastery grid
(`Ui.Charts.grid`, a square per position coloured by rung), the state line,
for a tier the cost lines, and one button that never disappears where
there is anything to practice (`Ui.Deck.action`: TRAIN, KEEP GOING,
PRACTICE ANYWAY, START, TRY). TRAIN is the one word for running a deck,
a tier's, a set's and a guest's pile alike. A row has `Ui.Charts.miniRing`.
Signed in, the page POSTs the browser's zone
(`Intl.DateTimeFormat().resolvedOptions().timeZone`, boot flag `tz`) to
`/papi/practice/tz` once per visit, never for a guest. Decisions on the
server: `handlers/practice` and `handlers/puzzles_hub` (TRY ONE's
clear-answer rule, on the `puzzles.sample` cap: up to 40 complete puzzles in
the database's random order, the first that qualifies). TRY ONE and the
status page draw only rows whose `origin` is `game` or `set`, never a
position somebody set up on the analysis board or shared from a replay
(`docs/analysis.md`); TRY ONE also skips any row a replay share linked
(`puzzles.replay`), so it never hands a stranger a door into a room.
A position shared from a replay (`origin = 'replay'`, no source row, so in
nobody's practice) shows "From a game on Oskol · WATCH THE REPLAY →" after
the reveal (`docs/analysis.md`, "Share a position from the replay").

**A deck's page** (`/practice/<slug>`, `assets/src/Page/Practice.elm`) is
`GET /papi/practice/decks/:slug`: the same card at page size
(`Ui.Deck.Size` `OnPage`, the grid as wide as the page with its legend),
the ladder in words, what is due, the last thirty days, and for a tier what
it cost and what mastering won back. A run started here comes back here.

The signed-in home's practice section is still the one-tier card
(`assets/src/Ui/Tiers.elm`, on `/papi/me/home`'s `practice`); the
good-shape and all-clear lines and "WORK ON ? BAD MOVES" live there only.

**The words are one module.** Every sentence practice is said in lives in
`assets/src/Ui/Mistakes.elm` (sets: `assets/src/Ui/Decks.elm`) and is pinned
in `MistakesTest`: the unit a player reads about is **a mistake they made**,
and what they do with it is **train** it (the button is TRAIN). The same
three states for all five decks, mistakes and sets alike: **to learn**
(never started), **learning** (started, below `deck.patched_level`) and
**mastered** (at or above it) -- "6 mastered · 18 learning · 20 to learn ·
of 44", "31 left to master", the legend "to learn · level 1 · 2 · 3 ·
mastered", and on the reveal "Mastered. Four right in a row — back in 21
days". The end of a run says "You mastered 2 very bad moves." (a set: "You
mastered 2 of them."). The day is "practiced", never "mastered": "3
practiced today". Nothing a player reads says card, deck or flashcard, nor
"fix", "patched" or "learned" (`MistakesTest` and `DecksTest` hold it);
`patched` lives on only as the wire's and the code's name for the top
rungs.

## Universal sets

A set is practice nobody's mistakes made, offered to everyone: today
**Openings** (the 15 opening rolls) and **Opening replies** (all 21 rolls
after each opening played the engine's best way: 315 positions, fewer
should two openings ever leave one board). What a set *is* -- its id, name,
line and new-a-day budget -- is the Gleam registry
(`src/oskol/practice/decks.gleam`, `all()`); **which** positions are in it
is data, `deck_puzzles(deck, puzzle_id, position)`, pointing at ordinary
`puzzles` rows (same key, same grading, same page -- an opening that is
also somebody's mistake is one puzzle in two places).

- **A set is its own retain scope per account** (`decks.scope`,
  `"deck:<id>"`). Retain keys a learner by (scope, uid) and every call
  takes `scope:`, so `Oskol.Gleam.Caps.Practice.build/1` is the same caps
  one scope along and `ctx.decks.practice(scope)` hands them to Gleam.
  `decks.in_deck(ctx, set)` swaps them in for `ctx.practice`, which is how
  every mistake rule (the attempt row, the advisory lock, first answer at
  a due card, SOONER/GOT IT/NEVER) holds for a set unchanged. The
  mistakes stay the default scope: a set can never spend their three new
  a day, touch a tier, or appear in `/papi/practice`. The reposition task
  walks the default scope only.
- **An answer names its set**: the attempt and the override carry `deck`
  (`handlers/puzzles.attempt_in_json` / `outcome_in_json`); none is the
  player's mistakes, a name that is no set (or somebody else's own set) is
  a 404. The run carries it
  (`Run.deck`), the strip names the set and draws its own ring, and the
  page asks no `/why` (a set's position came from no
  game). A set's position is "mastered", the mistakes' own word
  (`Ui.Decks`).
- **Adding is an account's; playing is anybody's.** `POST /papi/decks/:id/join`
  enrols every member in the set's scope at its position, with the
  browser's zone; a guest, a stranger and an account that has not added
  it walk the set in order with nothing written. `POST /papi/practice/tz`
  reaches every set the account has added (and its own sets) and creates none. The streak
  counts practice in every scope (`activity.practiced`).
- **Budgets**: Openings five new a day, replies ten, and KEEP GOING
  through a set (`POST /papi/decks/:id/more`) starts that many again.
  Patched is the same rung (`deck.patched_level`), read off the set's own
  ladder.
- **Built by the operator, from the engine, never by a migration.**
  `mix oskol.decks.build` (dry run unless `--write`;
  `Oskol.Release.build_decks(dry_run: false)` in a release) builds the
  openings, then the replies against the openings' best plays **as
  stored**. Every decision is `handlers/decks_build`: a position already
  in its set (by question key) is never asked again, a dry run asks
  nobody, an answer short of every legal play (`openings.answer`) is a
  failure and not a puzzle, and each batch is written as it lands. Money
  play, Jacoby, cube centered: unlimited play's own opening. A set with no
  positions built is not offered, so the page shows nothing until the
  build has run. Tests build both against `Oskol.CompleteEngine`
  (test_support), a stub that answers every legal play.
- **The pages**: a set is one of the five decks (above): a row or the card
  on `/puzzles`, and its own page at `/practice/<slug>`, with START (adds
  it), TRAIN (its queue), TRY (a walk, for anybody without an account).
  `/papi/decks` and `/papi/decks/:id` stay its session's endpoints. A new
  set is a registry entry (its slug is its id with `-` for `_`), a build for
  its positions, and nothing else.

## Own sets

A set an account makes for itself and saves positions into -- from the
analysis board, or from any puzzle -- and practices exactly as it practices
Openings. To a player it is a **set** ("Your sets", "Save to a set", "New
set"); in code, URLs and the wire it is a deck, like the others. It is the
universal-set machinery with an owner, so there are no new practice rules.

- **Rows.** `decks(id, user_id, name, new_per_day, deleted_at)`
  (`Oskol.OwnDecks`): the id is eight characters of the room-code alphabet
  minted by the `ids.deck_id` cap, which no universal id ("openings",
  "opening_replies") can be; the name is 1..40 characters, trimmed, unique
  per owner in any case among live sets (a partial unique index on
  `lower(name)`). Its positions are `deck_puzzles` rows under its id, as
  Openings' are, and its owner's ladder is the retain scope `"deck:<id>"`,
  as Openings' is, so `deck_members`, `deck_size`, `decks.queue`,
  `decks.anyway`, `decks.standing` and `Caps.Practice.build(scope)` work
  unchanged.
- **Gleam.** `practice/decks.Deck` has `owner: Option(String)` (None for
  the registry's two); `decks.own(ctx, uid)` reads the `decks.own` cap
  (live rows, oldest first) and `decks.find_for(ctx, session, id)` is the
  one lookup every door uses: the registry first (no IO), then the caller's
  own sets. `practice/catalog.Kind` has `Own(set)`, and `catalog.all(ctx,
  session)` is the five then an account's own sets (`catalog.five()` is
  the five). `handlers/own_decks` makes, renames, deletes, fills and empties
  one.
- **Private.** Every door that names a set -- `/papi/decks/:id` and its
  join and more, `/papi/practice/decks/:slug`, the page's head, an
  attempt's or an override's `deck`, and every `/papi/decks/:id/...` of
  its own -- answers somebody else's set with the same 404 as an id that
  names nothing ("There is no such set of puzzles."). Its page is noindex
  and never on the sitemap. Sharing a set is later; the row has room for a
  token.
- **Saving enrolls at once.** `POST /papi/decks/:id/puzzles {puzzle_id}`
  writes the member, under a lock on the set's row, at one past its highest
  position (`on conflict do nothing`) and puts that one item in the owner's
  scope (`put_user(uid, "", 5)`, then `put_items` with tags `{deck, kind}`
  and the question as its content, as `enroll` writes them), so it is due
  today as a new position. Idempotent: the second time is `added: false`.
  Taking it out suspends its card, then deletes the member (a half-done
  remove is finished by the next one); a suspended card counts for nothing
  in the set's standing or grid (`decks.shown_cells`). Saving it again
  resumes it at the level it had and moves it to the set's end (the
  `practice.place` cap). Joining an own set is a no-op: there is nothing to
  add.
- **Origin is not touched.** A position somebody analyzed stays `origin:
  analysis` when it is saved into a set, so it stays out of TRY ONE and
  the status page (`Oskol.Puzzles.sample/1` takes `game` and `set` only).
- **Pace and limits.** Five new a day, like Openings (`decks.new_per_day`,
  one column if a set ever wants its own); at most fifty live sets an
  account. Delete is soft (`deleted_at`): the row leaves every list and
  door, its membership and ladder stay, and its name is free again.
- **On the hub** an own set is a row after the five (`kind: "own"`,
  `mark: ""`, `joined: true` even when empty, the set's own standing), and
  its page (`/practice/<id>`) carries `members` for MANAGE, each with its
  `question` as the puzzle page shows it (`handlers/puzzles.
  stored_question_json`; null for a row that does not read as one).
- **The save sheet** (`assets/src/Ui/SaveToSet.elm`, `#save-modal`) is one
  component two doors open: SAVE on the analysis board's answer
  (`#an-save`) and SAVE on a puzzle's reveal (`#pz-save`). It reads
  `GET /papi/decks/mine?puzzle=<id>` (each set with `holds`), a row
  (`#save-set-<id>`, a checkbox) puts the position in or takes it out
  through `POST/DELETE /papi/decks/:id/puzzles` -- the check inked at once,
  put back on an error -- and "New set" (`#save-new-name`, CREATE
  `#save-create`) makes a set and then adds. One fixed-height line
  (`#save-line`): "Saved to Openings I like · 12 positions", "Taken out of
  ...", or the server's refusal ("You already have a set called that").
  A guest gets "Sign in to keep this position." over `Ui.SignIn`, `next`
  the page's own URL (the analysis board's carries `?xgid=`); signed in
  there, the shell is told and the sheet goes on to the sets. The list
  holds its height from loading to loaded; the sheet floats.
- **The client.** `Api.PracticeDecks.Kind` has `Own`, and `Ui.Deck` draws
  one with a bookmark for its icon, a set's words (learned, mastered) and
  a set's buttons (`Ui.Deck.action`: TRAIN / KEEP GOING / PRACTICE ANYWAY),
  and, while it holds nothing, OPEN ANALYSIS (`#hub-open-analysis`, a link
  to `/analysis`) in the button's slot over "Nothing here yet. Save a
  position from the analysis board or from any puzzle." The hub
  (`Page.Puzzles`) puts them after the five under "Your sets"
  (`#hub-your-sets`); a run from one is `StartDeckRun` with the set
  (`Run.InSet`), exactly as Openings'. Its page (`Page.Practice`) adds
  MANAGE (`#practice-manage`) under the card: the name in a field
  (`#practice-rename`, RENAME, `PATCH`), the positions as a list -- a 72px
  still board (`viewStill` on `Setup.fromQuestion`), the prompt (two lines
  at most, a roll never broken at its hyphen), where it stands ("to learn", "back at the start", "level 2", "mastered"), and an
  x (`#practice-remove-<pid>`) -- and DELETE SET (`#practice-delete`),
  which asks in its own slot ("Delete Openings I like? Its positions stay
  where they are; your progress on them is kept aside.", YES, DELETE
  `#practice-delete-yes`, KEEP IT) and then goes back to `/puzzles`.

`POST /papi/practice/tz {tz}` writes the browser's zone onto the deck itself
(no new column: retain already keeps a learner's timezone, and it is the
only thing that reads one). Gleam checks the shape, the zone database checks
the name; `Etc/UTC` until it is set, and filling a deck passes no zone so it
can never undo one. `POST /papi/practice/bury {id}` puts a puzzle the
session left ungraded back to the start of the player's tomorrow, level kept
-- 409 when it is not in rotation, which is what `error.Conflict` is for.
