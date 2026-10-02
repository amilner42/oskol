# URLs and the `/papi` JSON API

The routes are `lib/oskol_web/router.ex`; the decisions behind every answer
are Gleam handlers under `src/oskol/handlers/`. What each page shows a player
is in the Aveline doc `pages`; the subsystems behind the endpoints are in
[home.md](home.md), [reviews.md](reviews.md), [puzzles.md](puzzles.md) and
[identity.md](identity.md).

## URLs

The page URLs are Elm routes and server routes both: a visitor may
arrive at any of them cold, and moving between them afterwards is a
`pushUrl`, not a page load.

- `/` the home page, which is two pages: a guest gets OSKOL, a board
  playing by itself and one sentence over PLAY NOW (`Page.GameLanding`;
  see the Aveline doc `pages`), an account gets its own home --
  form and its streak, live games, practice, recent matches (`Page.Home`,
  from `GET /papi/me/home`). `Main` picks by the session and picks again when
  `/papi/me` lands, so a browser that turns out to be signed in ends up on
  its own home with no reload, and one that logs out is handed the board
  back. Until then `/` is a loading screen (`Ui.Loading`: the bar with only
  the bird, which both homes' bars start with, and a thin loading bar), up
  for at least a second from the page starting to load and until an
  account's home has its answer, so neither home flashes before the other.
  The server paints that same screen before the app boots (`spa.html.heex`)
  and the app's bar picks its animation up where the server's left it. The
  server serves the same shell either way.
- `/papi/library`, `/papi/games/:slug` (GET and POST) the landing pages as
  JSON for the Elm client. Public like the pages, session-based guest
  identity, CSRF token in `x-csrf-token`. Envelope: `{"ok": true, ...}` or
  `{"ok": false, "error": {"code", "message"}}` (404 not_found,
  422 validation_failed, 500 server_error).
- `/backgammon` create a game; `/backgammon?game=<id>` is the invite link.
  Its head is the invitation while the room waits for its second player:
  "Arie wants to play a match to 7 on a 5 min clock", what to do about it,
  and the opening position as the card's picture (`landing.invite_head`,
  in Gleam, from the room's row through the cap `persistence.room`: a
  crawler wakes no room, and the inviter is the seat's name, not a live
  connection's). Any other room -- started, over, unknown, another game's
  -- and the bare page get the game's own head; the canonical is always
  `/backgammon`, so an invite never competes with it
- `/backgammon/<id>` a running game — and, until the second player arrives,
  the waiting room: a room with no instance yet answers the game channel
  with a lobby payload. The URL says which room and nothing else; what it
  opens is the room's answer on the game channel, against the browser's
  guest cookie. A browser holding no seat there is refused ("unauthorized",
  never saying why) and the client sends it to the invite link, which is the
  one page that says whether there is a seat to take. A legacy `?t=` (seat
  tokens no longer exist) is ignored by every route and every handler.
- `/backgammon/<id>/replay?game=<n>&step=<s>` a room's games played again,
  a line of the record at a time, with the analysis engine's verdicts. It
  opens for anyone with the link -- a replay is what both players and any
  spectator already saw -- and is served the SPA shell, `noindex`. The board
  faces the reader's own seat when their guest holds one here, else the seat
  that played first, and the page turns the board around anyway. The table
  offers it from the match history and at game over. Board, steps and
  verdicts all come from `/record` and `/reviews`. The page keeps `step`
  current in the address bar (replaced, not pushed, so back still leaves
  the page), which is what makes a reload land on the same line and a
  link carry a move to a friend; `step` is omitted at the start of a game.
  OPEN IN ANALYSIS over the panel's tabs opens the step's decision on
  `/analysis?xgid=` in a new tab (`docs/analysis.md`).
- `/puzzles` the practice home, PUZZLES on the home menu: the five decks
  (three tiers of the visitor's mistakes, the sets), one in front with the
  button that starts a run (see [puzzles.md](puzzles.md)). Open to anyone, indexable, in the sitemap; the
  head (`SpaController.puzzles`) is "Puzzles" and the brief's one-liner,
  the same to everyone.
- `/practice/<slug>` one deck's own page (`very-bad`, `bad`, `dubious`,
  `openings`, `opening-replies`; see [puzzles.md](puzzles.md#the-five-decks)).
  The head is `practice.deck_head`'s: a set is indexable, with a canonical,
  and in the sitemap; a tier is somebody's own mistakes and is `noindex`; a
  slug that names no deck, a set nobody has built, and a bare `/practice`
  are a 404. `practice` is a reserved slug (before `/:slug` on both sides).
- `/puzzles/<id>` one puzzle: the position, "White to play 6-4. What's your
  play?", the board to play it on, then the reveal. Open to anyone with
  the link and indexable; `puzzles` is a reserved slug (before `/:slug` on
  both sides). The
  head (`SpaController.puzzle`, words from `handlers/puzzles.head`) is the
  question as the title and og:title, the score and cube as the
  description ("Match play, 3 away against 5. Cube centered."; no score is
  "Unlimited play", one point each way "Single game" unless Crawford, the
  picture's own words), the board's picture as og:image, nothing else; an
  id nobody stored is a 404. Not in the sitemap: too many. There is one
  prompt, `oskol/puzzles.prompt` ("White to play 6-4. What's your play?",
  "White to play. Double?", "White is doubled. Take?"): the wire, the head,
  the page and the picture all read it. `/puzzles/<id>?s=<token>` is a
  **story link** (`handlers/shares`): the same page, whose head says
  "Arie got this wrong. What's your play?" (the sharer's name, then the
  prompt's question: "Double?", "Take?") and whose reveal, after the
  reader's own attempt, adds "Arie played 24/23 13/11 (a bad move) and
  lost 2 points." The canonical stays the clean URL; the picture ignores
  `?s=`; a token nobody minted, or minted for another puzzle, is ignored
  and the page is the plain one. Only the seat that made the mistake can
  mint one (`POST /papi/puzzles/:id/shares`), and it names the sharer
  only, never the opponent.
- `/analysis` the analysis board (`SpaController.analysis`, declared
  before `/:slug` so "analysis" is a reserved word): a position set up by
  tapping, asked of the engine on a press (`docs/analysis.md`). Open to
  anyone, indexable and in the sitemap; the head is "Analysis", "Set up any
  backgammon position and ask the engine what it would play.", canonical
  `/analysis`, the same for every position. `/analysis?xgid=<id>` opens a
  position id (`Xgid.decode`; `href` writes it with its `=` and `:`
  percent-encoded, and a hand-typed one with them bare reads the same),
  `/analysis?p=<puzzle id>` a puzzle as its page shows it (the client
  reads `GET /papi/puzzles/:id`; no engine time). Neither changes the head.
- `/login/<token>` the page a mailed sign-in link opens. It **reads** the
  token and writes nothing: the page says "Sign in as you@example.com" with
  one button, and that button POSTs `/papi/auth/link`, which is the only
  thing that spends it. So a mail scanner prefetching the link cannot burn
  it and no other site can sign a visitor in. Under the button: "Opened
  this on another device? Enter the code from the mail there instead."
  Pressed, the page is the win every sign-in ends on ("You're in.", how
  many games came along, CONTINUE to where it was asked from), plus a line
  for a link that brought nothing, pointing at the other device. A dead
  token renders "That link has expired. We'll send a fresh one." over the
  sign-in (`Ui.SignIn`). Served the SPA shell, `noindex`; the flags
  (`state`, `email`, `next`) ride in a `login` meta tag. A bare `/login` names no game: 404. `login` and `dev` are
  reserved slugs (declared before the game routes).
- `/poker`, `/go`, `/chess` and anything under them: 302 to `/` (the games
  that were removed).
- `/puzzles/<id>.png` a puzzle's link picture (`OskolWeb.Plugs.PuzzlePicture`,
  an endpoint plug, not a route; see [puzzles.md](puzzles.md)).
- `/sitemap.xml` (`/`, each game's page, `/puzzles`, each built set's
  `/practice/<slug>`) and `/status` (is the
  analysis engine answering, and is it really the engine:
  `OskolWeb.StatusController`).
- Dev only (`:dev_routes`): `/dev/mailbox` and `/dev/last-login` (see
  [identity.md](identity.md#mail)).

## The `/papi` API

The landing pages read and write over JSON. Every response is the same
envelope: `{"ok": true, ...payload}`, or `{"ok": false, "error": {"code",
"message"}}` — including on a non-2xx status, so the client parses bodies
rather than leaning on the status. A refusal that passes with time (a 429,
a 503) adds `retry_after_s` to the error. Requests go same-origin, so the guest
cookie rides along and identity needs nothing from the client; writes carry
the page's CSRF token in `x-csrf-token`.

```
GET  /papi/library                     {ok, games, coming_soon, guest_name}
GET  /papi/games/:slug                 {ok, game, formats, clock_presets, copy, guest_name}
POST /papi/games/:slug                 {format, name, clock, opponent}
                                         -> {ok, id, path, player_id}
                                       `opponent` is `friend` (the link, and
                                       anything else) or `bot`; a bot game is
                                       forced to no clock and is already
                                       running when this answers
GET  /papi/games/:slug/rooms/:id       {ok, state, inviter_name, summary, disconnected}
POST /papi/games/:slug/rooms/:id       {name} | {player_id} -> {ok, id, path, player_id}
POST /papi/games/:slug/rooms/:id/close {} -> {ok, closed: true}  (a seat
                                       only, and only while the room has no
                                       game in it: a lobby nobody joined.
                                       422 "You are not at this table" for
                                       anyone else, 422 "That game already
                                       started" once there is a game, 404
                                       for a room no row remembers; a second
                                       press is the same yes)
GET  /papi/games/:slug/rooms/:id/reviews  (open) the index, and only the index
                                       {ok, players, games: [{game_number,
                                           status, turns}]}  -- a few hundred
                                       bytes for a whole match
GET  /papi/games/:slug/rooms/:id/reviews/:game_number  (open) one game
                                       {ok, game_number, status, turns, review}
                                         review is null unless status is done;
                                         when it is, {levels, timing_ms, players,
                                         turns}; a turn names its record lines
                                         (entry, double_entry, answer_entry) and
                                         each candidate move its position and
                                         landings. A number the room has no game
                                         for is a 404.
POST /papi/games/:slug/rooms/:id/reviews/retry  {game_number} -> the index, a
                                         failed game queued again (a seat only)
GET  /papi/games/:slug/rooms/:id/record  (open)
                                       {ok, slug, id, you, seated, accounts, record}  (the game's
                                       `record`; `you` is the seat the board faces --
                                       the reader's own, else the first -- and `seated`
                                       says whether that seat is theirs). Each of
                                       `record.games` is {number, crawford, entries}:
                                       `crawford` is true on the match's Crawford game
                                       (`backgammon/record.crawford_game`, the rule
                                       `state.next_game` applies, over the scores the
                                       result lines left; false in unlimited play and
                                       on a match's first game), which the replay's
                                       OPEN IN ANALYSIS carries
GET  /papi/games/:slug/rooms/:id/ratings  (open) {ok, players: [{player_id,
                                       games, pr, career}], games:
                                       [{game_number, players: [{player_id,
                                       pr}]}]} -- each seat's PR over the games
                                       of THIS match the engine has graded (null
                                       while it has graded none), `career` the
                                       same seat's account over every graded game
                                       it has played (null for a seat no account
                                       owns and under 5 games), and each graded
                                       game's PRs by seat, for the match panel
GET  /papi/puzzles/:id                 (open) {ok, id, kind, question, tree,
                                         prompt} -- the position, the sentence it
                                         asks in, and for a checker play every
                                         legal way to play the roll as a DAG of
                                         boards. Never the answer, never a name,
                                         never the game it came from
GET  /papi/puzzles/:id/tree?node=      (open) one level of a tree too big to send
                                         whole: {ok, node, tree: Node}
POST /papi/puzzles/:id/attempts        {moves | band, key, s?, deck?} -> {ok, verdict, band,
                                         cost, yours, best, top, cube, schedule,
                                         story}. `verdict` is pass, fail or unknown
                                         (hold only on a retried key from before
                                         0.02 became a miss); `band` the grade the
                                         answer's cost falls in (best, ok, doubtful,
                                         bad, very_bad, unknown); `schedule` is
                                         {level_before, level_after, due, amendable,
                                         self_grade, held_days, patched}. Open; a
                                         guest and a puzzle outside the caller's deck
                                         get schedule: null and nothing is written.
                                         `s` is the story token the page was opened
                                         with: `story` is {name, kind, played, grade,
                                         equity_lost, date, result, headline, line}
                                         where it opens one for this puzzle, else
                                         null -- on the reveal and nowhere earlier
POST /papi/puzzles/:id/attempts/:key/outcome  {outcome: sooner|got_it|knew_it|never, deck?}
                                         -> {ok, schedule}. The attempt's own
                                         account only (403); 409 with nothing to
                                         amend; 422 for got_it on an answer
                                         graded a miss
POST /papi/puzzles/:id/shares          {} -> {ok, token, url}  (the seat that
                                       made the mistake, by the holder rule --
                                       guest or account -- mints its story link,
                                       `/puzzles/:id?s=<token>`, the same one on
                                       every press; the opponent and a stranger
                                       are a 403 in one sentence; a GET never
                                       mints)
GET  /papi/puzzles/:id/mine            (a seat in the source game, either side)
                                         {ok, who, opponent, played, equity_lost,
                                         grade, date, result, replay}; 404 otherwise.
                                         `who` is "you" or the other seat's display
                                         name; `opponent` the other seat's, always;
                                         `date` the day the game ended (its review
                                         row's), never the day the source was written
GET  /papi/puzzles/:id/why             (a seat in the source game, either side)
                                         {ok, who, opponent, grade}; 404 otherwise.
                                         Why this position is in front of you, asked
                                         **before** the answer: the band and whose
                                         game it was, and nothing derived from the
                                         answer -- no move played, no equity, no
                                         result. The session's quiet line over the
                                         board; a shared link is a 404 and says
                                         nothing
GET  /papi/games/:slug/rooms/:id/puzzles?game=n  (a seat) {ok, puzzles: [{id, kind,
                                         prompt, due}], cursor, counts, today, game}
                                         -- 404 without a seat; 409 `puzzles_pending`
                                         while the game's review is done but its
                                         puzzles are not yet written (the page
                                         asks again in a moment)
POST /papi/analysis                    a set-up position (analysis/setup's wire:
                                         {points, white_bar, black_bar, to_play,
                                         ask, dice, cube: {value, owner}, match})
                                         -> 200 {ok, status: "done", key, puzzle,
                                         reveal} when the question's puzzle row is
                                         complete (free, nothing charged); 202 {ok,
                                         status: "pending", key} when handed to the
                                         asker or joining the same key in hand. 409
                                         `dances` "6-4 cannot be played from here"
                                         (nothing asked); 422 `validation_failed`
                                         with the setup's sentence; 429
                                         `rate_limited` {message, retry_after_s}
                                         over a budget or with the line full; 503
                                         `engine_down` "The engine is asleep. Try
                                         again in a minute." {retry_after_s} while
                                         the circuit is open. `puzzle` is GET
                                         /papi/puzzles/:id's object (id, kind,
                                         question as shown, tree, prompt); `reveal`
                                         is {best, top, cube, n_legal, levels}: the
                                         attempt reveal's own best/top/cube with
                                         nobody's answer in it, n_legal (null for a
                                         cube), levels {moves, cube} | null
GET  /papi/analysis/:key               {ok, status: "pending"} | {ok, status:
                                         "done", key, puzzle, reveal} | {ok,
                                         status: "failed", message}; a key no row
                                         answers and the asker has not seen (in ten
                                         minutes, or since a restart) is a 404.
                                         The page polls this once a second
POST /papi/analysis/moves              {setup, node?} -> {ok, tree}: every legal
                                         play of a set-up roll, for a step of the
                                         line played out on the board. The puzzle
                                         page's tree (GET /papi/puzzles/:id's
                                         `tree`: the mover drawn as White, `lazy`
                                         with the root alone past the wire budget),
                                         worked out by move generation and never
                                         the engine; nothing is written. With
                                         `node`, {ok, node, tree: one node} as GET
                                         /papi/puzzles/:id/tree?node= serves a
                                         level (404 for an id the build never
                                         minted). A roll that plays nothing is a
                                         root with no children. 422
                                         `validation_failed` with the setup's
                                         sentence, or "Only a roll has moves to
                                         play" for a cube question; 429
                                         `rate_limited` past 120 a minute a caller
                                         (3000 a minute everybody), kept by the
                                         same limiter as the asks
GET  /papi/codes/:code                 {ok, slug, code}  (the code as typed, else
                                       normalised: the one that answered comes back)
POST /papi/auth/start                  {email, next?} -> {ok}  (always ok: no
                                       enumeration; over a rate limit it sends
                                       nothing and says the same. Mails a link and
                                       a six-digit code)
POST /papi/auth/link                   {token} -> {ok, saved, next, user, new}
POST /papi/auth/code                   {email, code} -> {ok, saved, next, user, new}
                                       (the code redeems only from the browser that
                                       asked; 5 tries, then dead)
POST /papi/auth/logout                 {ok}  (nilifies guests.user_id and drops
                                       this browser's sockets)
GET  /papi/me                          {ok, guest_name, user: {email, name} | null}
POST /papi/me/name                     {name} -> {ok, user}  (a signed-in browser
                                       renames its account; 422 "That name is
                                       taken." when another account has it)
GET  /papi/practice[?band=<grade>][&all=1[&from=<n>]]
                                       {ok, puzzles: [{id, kind, prompt, due}],
                                         cursor: null, counts: {due,
                                         new_today, new_tomorrow, deck} | null,
                                         mistakes: {puzzles, games} | null,
                                         today: {done} | null,
                                         severity: [{grade, total,
                                           in_progress, patched, due,
                                           new_left}] | null,
                                         lead: "<grade>" | null,
                                         patched_level, game: null}
                                       -- an account's deck (due, then new;
                                       new_tomorrow is the day's budget or
                                       the cards never seen, whichever is
                                       fewer), a guest's own mistakes
                                       (unscheduled, counts null, no writes;
                                       `mistakes` counts all of them, from
                                       how many games), or nothing. `today`
                                       is a plain count of the answers
                                       recorded in the caller's own local
                                       day: **no target, and so no quota**.
                                       `severity` is the mistakes by band,
                                       worst first, each in three states --
                                       untouched, in progress (started,
                                       below the patched rung) and patched --
                                       plus what that band still has to do
                                       today: `due` now, and `new_left`,
                                       the ones it has never shown that the
                                       day's budget of new mistakes still
                                       allows (the budget is the deck's, not
                                       the band's). `lead` is the worst band
                                       with work, else the worst the player
                                       has made a mistake in at all, else
                                       null -- one choice, so the hub and the
                                       home cannot make it two ways. All an
                                       account's only. `?band=` narrows the
                                       puzzles to that one tier, due first and
                                       then ones never seen, worst first
                                       inside it: what TRAIN runs; a guest's
                                       `?band=` narrows their mistakes the same
                                       way. A band that is not one of the three
                                       is a 422, never the whole deck. `all=1`
                                       is PRACTICE ANYWAY: only when the queue
                                       is empty, the cards in rotation soonest
                                       due first (`due: false`, nothing moves);
                                       `from=<n>` skips the first n of them.
                                       Never paged: every fetch is the front of
                                       the queue
GET  /papi/practice/decks              {ok, decks: [{id, slug, kind, name, mark,
                                         blurb, size, pace, joined, standing:
                                         {total, untouched, in_progress, patched,
                                         due, new_left, done_today, target_today,
                                         levels} | null, cost: {games, lost,
                                         lost_patched, pr, pr_without,
                                         pr_patched} | null}], lead, today: {done}
                                         | null, streak, patched_level, cost_all:
                                         {pr, pr_without, pr_patched} | null,
                                         mistakes: {puzzles, games} | null}
                                       -- the five decks (three tiers, the built
                                       sets) for the hub, then an account's own
                                       sets (`kind: "own"`, `mark: ""`,
                                       `joined: true`, offered empty); `standing`
                                       an account's, `cost` an account's tier with
                                       3+ graded games, `mistakes` a guest's.
                                       Writes nothing ([puzzles.md](puzzles.md#the-five-decks))
GET  /papi/practice/decks/:slug        {ok, deck, cells: [{id, level, due, status,
                                         position, band}], days: [30 bools],
                                         patched_level, members: [{id, kind, prompt,
                                         position, level, question}] | null} -- one deck's
                                       page; `members` only on an own set (its
                                       slug is its id). 404 for an unknown slug,
                                       an unbuilt set, or somebody else's set
GET  /papi/decks                       {ok, decks: [{id, name, blurb, size, standing:
                                         {joined, total, in_progress, patched, left,
                                         due, new_left} | null, own}], patched_level}
                                       -- the universal sets with positions built
                                       (see [puzzles.md](puzzles.md#universal-sets)),
                                       then the caller's own sets (`own: true`);
                                       `standing` is an account's
GET  /papi/decks/:id[?all=1[&from=<n>]]  {ok, deck, puzzles: [{id, kind, prompt, due}],
                                         today} -- an account that added it gets
                                       its queue (due, then new within the set's
                                       own budget); anybody else walks it in
                                       order, nothing written. `all=1&from=` is
                                       PRACTICE ANYWAY, as on /papi/practice.
                                       404 for a set that names nothing, has
                                       nothing built, or is somebody else's
POST /papi/decks/:id/more              KEEP GOING through a set: its own pace
                                       again of positions never shown, over the
                                       day's budget, then the session (409
                                       `sign_in` / `not_joined` for anybody
                                       who has not added it)
POST /papi/decks/:id/join              {tz} -> the same session, once the set is
                                       added (an account's; 409 `sign_in` for
                                       anybody else). Idempotent: adding again
                                       adds only positions built since. A no-op
                                       for an own set (saving enrolls)
GET  /papi/decks/mine[?puzzle=<id>]    {ok, decks: [{id, name, size, new_per_day,
                                         standing[, holds]}]} -- the caller's own
                                       sets, oldest first; [] for a guest. With
                                       `puzzle`, each says whether it holds that
                                       puzzle (the save sheet's checks)
                                       ([puzzles.md](puzzles.md#own-sets))
POST /papi/decks/mine                  {name} -> {ok, deck} (the same shape as one
                                       of the list): make a set. 409 `sign_in`
                                       for a guest; 422 `name_missing` "Give it a
                                       name", `name_too_long` "40 characters at
                                       most", `name_taken` "You already have a
                                       set called that", `too_many_sets` "That
                                       is a lot of sets" (50)
PATCH /papi/decks/:id                  {name} -> {ok, deck}: rename (the same
                                       422s); 404 unless it is the caller's
DELETE /papi/decks/:id                 {ok}: delete (soft; the ladder is kept);
                                       404 unless it is the caller's
GET  /papi/decks/:id/puzzles           {ok, deck, members: [{id, kind, prompt,
                                         position, level, question}]} -- the set
                                       and what is in it, for its owner (`question`
                                       as GET /papi/puzzles/:id has it, null where
                                       a row does not read); 404 for anybody else
POST /papi/decks/:id/puzzles           {puzzle_id} -> {ok, deck, added}: save a
                                       stored puzzle at the end of the set and
                                       enroll it at once (due today as new);
                                       `added: false` when it was there already.
                                       404 for a puzzle that is not stored, or a
                                       set that is not the caller's
DELETE /papi/decks/:id/puzzles/:puzzle_id  {ok, deck}: take it out; its card is
                                       suspended, so saving it again keeps its
                                       level
GET  /papi/puzzles/random              {ok, id, kind, prompt}  TRY ONE: a
                                       random complete puzzle whose answer
                                       stands clear (a checker play whose
                                       runner-up gives up 0.02 or more, a
                                       cube in an outer band, |margin| >=
                                       0.08); 404 with a sentence while the
                                       pool has none. Reads nothing about
                                       the caller and writes nothing
POST /papi/practice/more               {band} KEEP GOING: the deck's pace
                                       (`deck.keep_going_new`, three) of new
                                       mistakes into rotation over the day's
                                       budget, of that tier ("" the whole
                                       deck), then that tier's session; a
                                       guest's is the session, nothing written
POST /papi/practice/tz                 {tz} -> {ok, tz}  (an IANA name, on the
                                       account's deck; Etc/UTC until set)
POST /papi/practice/bury               {id} -> {ok, id, level, due}  (back at
                                       the player's own midnight, level kept;
                                       409 when it is not in rotation)
GET  /papi/me/prefs                    {ok, prefs}
POST /papi/me/prefs                    {key, value} -> {ok, prefs}
GET  /papi/me/games                    {ok, games: [{slug, id, path, status,
                                         opponent, format, clock, your_move,
                                         closable,
                                         time: {mine_ms, theirs_ms, running,
                                         free_ms, age_s} | null, idle_s}]}
                                       -- the unfinished rooms the caller
                                       holds a seat in (holder rule), newest activity
                                       first, from the rows alone.
                                       `closable` is whether the list itself
                                       may end this room (a lobby): the
                                       server's call, never a format the
                                       client reads
GET  /papi/me/home                     {ok, signed_in: false} for a guest;
                                       else {ok, signed_in: true, live, form,
                                       practice, recent, more, next} -- the
                                       whole signed-in home in one answer
                                       (see [home.md](home.md))
GET  /papi/me/games/graded?before=<cursor>
                                       {ok, rooms, more, next} -- the next ten
                                       recent rooms (a match, a session or a
                                       single game, with its graded games
                                       inside). `before` is the previous
                                       answer's `next` and nothing else; a
                                       mangled one is a 422, never the first
                                       page again
```

`path` is the URL of the seat that was just taken (`/:slug/:id`, carrying
nothing): the client goes there, and the seat waits in the lobby until its
opponent arrives. The seat is held by the guest cookie the write came with,
so the same URL is what anyone would be given for that room. `state` is
`open` (a free seat), `away` (a seat whose player is gone and that anyone
with the code may take back), `owned` (the only seats free belong to
accounts: nothing on offer), `seated` (with `path`: the caller already
holds a seat there, by its guest or its account, and the client goes
straight to the table), `full` (both players are there) or `missing`
(the room is over). `disconnected` names only the seats a visitor may
actually take, so an owned seat is never listed and nothing on the page can
be typed at it.

A game's own `clocks` are preset ids; `clock_presets` carries every preset,
so the picker can name the ones the game offers. Statuses: 404 `not_found`
(no such game, no such code, a room that is over), 422 `validation_failed`
(a name, a mode, a clock or a seat the room refused), 409 `not_in_rotation`
(a puzzle the session has moved past), 500 `server_error`.
Every decision behind these lives in `src/oskol/handlers/landing.gleam`,
except the record's, in `src/oskol/handlers/record.gleam`, and the reviews',
in `src/oskol/handlers/reviews.gleam`. A lobby, a slug that is not the
room's game and a room that is gone all answer the same 404, as the game
channel refuses without saying which. The caller's guest (the cap
`seated_game`, which answers which seat a guest holds) picks the seat the
record's board faces, and is what a retry takes. Nothing a reader does
spends engine time.

`/papi/me/games` is what the home page opens with: every room in `waiting`
or `playing` where the caller holds a seat by the holder rule — the guest
that took an unowned seat, or the account that owns one, so an account's
games follow it to any browser it signs in on and a browser that logged
out is offered none of them — read from `games` with no room woken
(`Persistence.seated_rooms`, the cap `persistence.seated_rooms`, the
handler `landing.my_games_json`, which asks `seat.held_by` of each room
and drops the rooms where the answer is nobody). Each
entry names the opponent (null in a lobby), the format and clock by name,
whether it is the caller's turn (`your_move`, from the row's `state`), the
two clocks as the snapshot last read them with how long ago that was
(`time`, so the client can charge the running one and count it down), and
seconds since the room was touched. The guest home (`Page/GameLanding.elm`)
offers them as "N live games" in its bar's ☰ (with a dot on ☰) for as
long as there are any, and the list opens only when that is pressed: nothing pops up over the page a
player came to play on. Nothing prunes games (they
are kept, finished or not), so nothing bounds the list -- but a lobby
nobody joined can be closed from its own row (`closable`; see [rooms.md](rooms.md#ending-a-room)).

`/papi/me/prefs` is the visitor's own display taste — today the backgammon
board's colours, under `backgammon_theme`. Gleam owns the whitelist
(`src/oskol/guests/prefs.gleam`): an unknown key or a value that names no
theme is a 422 and nothing is written. It is display only: a theme never
reaches a scene, an event or the game channel, and each player's board is
their own. The client also keeps the pick in `localStorage` (the `storePref`
port), which is what paints the board before the round trip and all a
visitor whose guest cookie is gone has.
