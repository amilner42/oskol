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
  answer from the fixed engine has every such play asked. Skipped turns are
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
  0.02 passes, under 0.08 holds, worse misses, and a board the stored answer
  has no result for is `unknown` -- old five-candidate rows -- so nobody is
  told they were wrong on evidence we do not have. A cube question is answered
  with a side, as at the table (double or not, take or pass); the engine's
  verdict is finer: the doubler's margin is `min(DT, DP) - ND`, the
  responder's is `DP - DT` (positive means take, because the responder picks
  whatever pays the doubler less), bands at 0.08 and 0.02 either side of
  zero. The right side passes, the wrong side misses, and when the engine's
  band is zero (too close to call) either side holds: nobody fails a coin
  flip. The reveal shows the engine's pick among the three equities and the
  chances, nothing more.
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
  it. NEVER suspends the card without touching the attempt's own schedule,
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
  What's your play?" / "Double?" / "Take?") and puts `story` on the
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
  move, the cube at its owner's side, the score line, the prompt. Text is
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
the same transaction as the sources and again when a sign-in stamps that
game's seats (`Oskol.Puzzles.refresh_owners/1`). It is an index key, never
an authority: `seat.holder` still decides, in Gleam, of every row handed
back. Without it the sweep's question is a lateral join over every unsynced
row every minute, and since a guest's mistakes are never synced that set
grows for ever. `ended_ms` is the game's **review row**, not the source's:
newest game played first, so a backfill or a retried review cannot put an
old game at the front; within one game, turn order. A card's position is
seconds *back* from 2020, not negated Unix time: retain's `position` is a
32-bit column.

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
timezone by exactly what the 30-day strip counts as practice, with **no
target** -- `severity`, the
mistakes by band in their three states (untouched, in progress, patched)
with what each still has to do today (`due` now, `new_left` capped at the
day's budget of new mistakes), and `lead`, the worst band with work
(`practice.severity`, which takes `deck.patched_level` and never decides
it; `deck.tiers` folds in the budget and `deck.lead` chooses). `?band=`
narrows the puzzles to one tier (`practice.band_queue`, the same
orderings `Retain.due` and its new-card query use, with the
`puzzle_sources` join in front): due first, then ones never seen, worst
first inside the band, and never the whole deck for a band that is not
one of the three. A guest: the mistakes on the seats their
cookie holds and no account owns, newest game first, unscheduled,
`counts: null`, and **nothing written** -- only an account has a deck.
Nobody: an empty list, not an error. Reading never starts a card or spends a
day's budget. `POST /papi/practice/more` puts ten more into rotation over
the day's budget and answers the same session; nothing in the client
presses it.

**A session is never paged.** Every fetch is the front of the queue and
`cursor` is always null. The due set is live -- answering a card takes it
out -- so a second page at an offset would skip exactly as many cards as the
player had just answered: 21 due would end after 20 with one unseen and the
day's new cards never offered at all. "Done for today" is a fetch that comes
back empty, and nothing else.
## The pages (client wiring)

What a player sees on these pages, and in which words, is the Aveline doc
`pages` (the one-tier card, the run, its end). The wiring:

**The puzzle page** (`/puzzles/:id`, `assets/src/Page/Puzzle.elm`) fetches the
question and nothing else until PLAY: the answer is not in that response,
and `/mine` is asked only after the attempt, so a page open on a shared
link can put nothing within reach. The board is the table's own
(`Games/Backgammon/Puzzle.elm` on `View.viewPlay`; a lazy tree's levels
are fetched as the path reaches them), UNDO and PLAY are its own band; a
cube question is two buttons, as at the table (DOUBLE / NO DOUBLE, TAKE /
PASS). The reveal is the replay's words and table (`Words`, with
`doubleWhy`/`noDoubleWhy`/`answerWhy` for a position nobody has acted on
yet) with "you" marked and a candidate tappable onto the board; the cube's
scale marks the engine's band over `cubeLine`. The attempt's key is minted
once per page load (`elm/random`) and a PLAY that lands before it waits for
it, so a retry is the same answer. Signed in with a `schedule`, the level
line ("Level 2 → 3 · back in 7 days"; "back tomorrow") and SOONER / GOT IT /
KNEW IT / NEVER, the graded one preselected when `amendable` (SOONER after a
miss, GOT IT otherwise), none when `self_grade`, absent when neither; NEVER
says the card is out of the deck. A schedule carries `patched`, true when
that answer took the mistake to `deck.patched_level` from below (the level
line then reads "Patched. Four right in a row — back in 21 days",
`.pz-level.is-patched`). SHARE is the table's `shareInvite` port on the
clean URL.

**A run is the shell's.** `Main.Run` is `{ids, at, answers, next, tier,
deck}`, kept across `pushUrl`s because every page is rebuilt on one. A page
that starts a run answers `Out = StartRun (List String) (Maybe Today)
(Maybe String)`: Main sets the run, takes the day's count from the answer
that page already had, and pushes the first id; `next` is the page the run
was started from (the practice home, the table, the replay), and is where a
guest who signs in at the run's end goes on to. FIX ONE fetches its tier's
queue (`GET /papi/practice?band=<grade>`) and starts a run of it. The page
is told `hasNext` and `progress` (`{at, marks}`), draws the strip over the
board (`#pz-progress`: the tier's mark and the day's count, a mark per
mistake answered, and the `/why` line, asked only in a session), offers
ANOTHER (`#pz-next`, `WantsNext`, only where there is another) and I'M DONE
(`#pz-done`, `WantsEnd`) after every reveal, and reports every reveal and
every override as `Out = Answered {verdict, schedule, grade}`; Main keeps it
by puzzle id (an answer given again replaces). `WantsEnd` is answered with
`Page.Puzzle.endRun {right, close, total} [answers]` -- a pass is right, a
hold close, a miss or an unknown neither, and `total` is **how many were
answered**, never the length of the list the run was given. Ending a run
fetches nothing. The page's other `Out`s: `SignedIn (Maybe User)`, `Go
path`.

**The practice home** (`/puzzles`, `assets/src/Page/Puzzles.elm`) is one
page on `GET /papi/practice`'s one answer; the one-tier card is
`assets/src/Ui/Tiers.elm`, the same on the hub and the home. Signed in, it
POSTs the browser's zone (`Intl.DateTimeFormat().resolvedOptions().timeZone`,
boot flag `tz`) to `/papi/practice/tz` once per visit, never for a guest.
`new_per_day` (three) is the only cap: there is no day's target. Decisions
on the server: `handlers/practice` (counts, the tiers, a guest's
`mistakes`) and `handlers/puzzles_hub` (TRY ONE's clear-answer rule, on the
`puzzles.sample` cap: up to 40 complete puzzles in the database's random
order, the first that qualifies).

**The words are one module.** Every sentence practice is said in lives in
`assets/src/Ui/Mistakes.elm` (sets: `assets/src/Ui/Decks.elm`) and is pinned
in `MistakesTest`: the unit a player reads about is **a mistake they made**,
what they do with it is **fix** it, and one they have stopped making is
**patched**. Nothing a player reads says card, deck or flashcard.

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
  player's mistakes, a name that is no set is a 422. The run carries it
  (`Main.Run.deck`), the strip names the set ("Openings · 3 practised
  today"), and the page asks no `/why` (a set's position came from no
  game). A set is "learned", never fixed or patched (`Ui.Decks`).
- **Adding is an account's; playing is anybody's.** `POST /papi/decks/:id/join`
  enrols every member in the set's scope at its position, with the
  browser's zone; a guest, a stranger and an account that has not added
  it walk the set in order with nothing written. `POST /papi/practice/tz`
  reaches every set the account has added and creates none. The streak
  counts practice in every scope (`activity.practised`).
- **Budgets**: Openings five new a day, replies ten. Patched is the same
  rung (`deck.patched_level`), read off the set's own ladder.
- **Built by the operator, from the engine, never by a migration.**
  `mix oskol.decks.build` (dry run unless `--write`;
  `Oskol.Release.build_decks(dry_run: false)` in a release) builds the
  openings, then the replies against the openings' best plays **as
  stored**. Every decision is `handlers/decks_build`: a position already
  in its set (by question key) is never asked again, a dry run asks
  nobody, an answer short of every legal play (`openings.answer`) is a
  failure and not a puzzle, and each batch is written as it lands. Money
  play, Jacoby, cube centred: unlimited play's own opening. A set with no
  positions built is not offered, so the page shows nothing until the
  build has run. Tests build both against `Oskol.CompleteEngine`
  (test_support), a stub that answers every legal play.
- **The page**: `/puzzles` draws a second card, LEARN, under the
  mistakes: a row per set with its line, the account's standing ("11
  left to learn · 4 learned") and one button -- START (adds it), PRACTICE
  (its queue), TRY (a walk, for anybody without an account) -- or "Nothing
  due. More of them tomorrow." A new set is a registry entry, a build for
  its positions, and nothing else.

`POST /papi/practice/tz {tz}` writes the browser's zone onto the deck itself
(no new column: retain already keeps a learner's timezone, and it is the
only thing that reads one). Gleam checks the shape, the zone database checks
the name; `Etc/UTC` until it is set, and filling a deck passes no zone so it
can never undo one. `POST /papi/practice/bury {id}` puts a puzzle the
session left ungraded back to the start of the player's tomorrow, level kept
-- 409 when it is not in rotation, which is what `error.Conflict` is for.
