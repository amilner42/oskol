# Identity: guests, seats, accounts, sign-in, mail

Who holds a seat and why. The rule every door asks is `seat.holder` in
`src/oskol/rooms/seat.gleam`. What the sign-in looks like to a player (where
it is offered, its words) is in the Aveline doc `pages`.

## In brief

The first player picks everything (opponent, mode, clock). Against **a
friend** they share a link and the game starts the moment the second player
types a name; against **the bot** (Sage, the analysis engine playing live)
the table fills itself and the game is going before the page has finished
loading. A bot seat holds no guest and no account, so nobody holds it and no
room code opens it, and it is never away, so the invite link has nothing to
offer. **A seat is held
by the guest cookie that took it** (`OskolWeb.Plugs.GuestId`: opaque,
HttpOnly, year-long), and no URL anywhere carries a secret: a player's link
is the plain room URL. A seat whose holder is away can be claimed from the
invite link by anyone with the room code -- friends playing, not security --
and it is that browser's from then on. One browser holds one seat at a
table, whichever door it came in by: a guest already seated there is
refused a second, on joining and on claiming alike (claiming back the seat
it already holds is how a closed tab comes back). The room code is
therefore the only thing between a stranger and a live game, so a code is
six characters of a 32-letter alphabet (about 1.07 billion), not six digits.
A display name is display only and grants nothing. A socket also names its
**client** (a per-tab id the browser mints; it authenticates nothing): the
room compares it with itself to tell one tab reconnecting -- a reload, a
route change, a phone waking its websocket up -- from another tab taking the
seat over, which is the only case the connection that had it is told about
(`src/oskol/rooms/seat.gleam`). **Accounts** are a guest grown up: sign in
by email (a mailed link, and the same sign-in as a six-digit code) and
`guests.user_id` names the account on that browser, which is why identity
has no second mechanism beside the guest. **A seat an account holds is
that account's**: `seat.holder` is the one rule every door asks — an owned
seat (`games.players[i].user_id`) answers to its account, from any browser
signed into it and from no other, the guest on it ignored; an unowned seat
answers to the guest that took it. An owned seat is
therefore not claimable: the invite link says `owned` and offers nothing.
Signing in **stamps** every unowned seat this browser holds onto the
account and **rotates** its guest id in the same write, so the id it
arrived with opens nothing afterwards. A browser that never signs in is
never bound: its seats stay unowned and it plays exactly as a guest always
has.

## Guests

Every visitor silently becomes a guest: `OskolWeb.Plugs.GuestId` mints an
opaque crypto-random id into a year-long HttpOnly cookie (renewed on every
visit) and mirrors it into the session (which is how the game socket's upgrade
request carries it). `Oskol.Guests` touches the guest's row and remembers
the last display name they played under (last writer wins); that name
prefills the create and join forms, and each seat in `games.players` records
the guest id. The same row carries `prefs` (jsonb): display preferences that
follow the guest between browsers, written through `/papi/me/prefs` and
whitelisted in `src/oskol/guests/prefs.gleam`. A guest who signs in gets
`guests.user_id` (indexed, read once per request by `CtxBuilder` into
`Session(guest_id, user_id)`, and once per socket connect, where the
channel hands it to the room with the guest); logging out
nilifies it and drops that browser's sockets (`UserSocket.id/1` is
`"guest:<guest id>"`), so a tab at a table the account owns is disconnected
and refused when it tries to come back. The id is also the credential:
a seat is held by the guest that took it (or by the account that owns it),
the game channel attaches on it
(the socket reads it off the session that the websocket's own upgrade request
carried, which Phoenix hands over only against the page's `_csrf_token`), and
losing the cookie loses the seats it was holding — they can be claimed back
from the invite link, like anyone else's.

## Accounts

**An account shows up by its username, never its email.** `users.name`
is citext and unique (`UniqueUsernames`). A new account is named at its
first sign-in (`handlers/auth.named`, on the rule `guests/username.candidates`):
the name the browser last played under as a guest, else that with a number
(`arie1`, `arie2`...), else `player1`, `player2`...; the win says "You'll
show up as arie1 · Change" (`Ui.Username`, `POST /papi/me/name`). A
signed-in browser is never asked for a name: CREATE GAME and the invite's
join form show "Playing as arie1", and the server seats it under the
username whatever it is sent (`landing.seat_name`). Wherever a name is shown
(the home bar, both player bars at the table, the replay) a badge says
guest or account (`Ui.Identity`): the channel's seat list carries
`account: true|false` per seat and the record carries `accounts` (player
ids), a yes or no only, never which account. **A seat points at the
account, it does not copy its name.** `games.players[i].name` stays the
name typed at the door; where the seat has a `user_id`, what everyone
sees is `users.name` — resolved as rows are read
(`Persistence.display_names/1`, behind the rooms and records caps, and
`names` in the record) and held in the live room's memory
(`connection.username`, filled on join, claim, rematch, rehydrate and the
sign-in stamp; `GameServerState.display_name/1`). So a rename is one row:
`POST /papi/me/name` writes `users.name`, tells the live rooms holding
that account's seats (`GameServer.rename/3`, nothing persisted), and every
game past and present shows the new name at once. A guest's home bar has the
same ☰ as an account's, with SIGN IN in it.

**Accounts** are `users` (uuid id, `email` citext unique, `name` citext
unique, `last_login_at`) and `login_tokens` (a sign-in in flight: `email`,
`token_hash`, `code_hash`, the `guest_id` that asked, `next`, `expires_at`,
`consumed_at`, `attempts`), both `Oskol.Auth`. An account is an email
address and nothing else — no password, so nothing to reset or leak.

**A seat can be owned.** Each entry in `games.players` is `{id, name,
guest_id, user_id, bot}`, and `user_id` is the account it belongs to (absent
on a row written before accounts: that seat is simply unowned; `bot` is
absent on every row written before the bot, and false is right for them). Who may open
it is one rule, in Gleam — `src/oskol/rooms/seat.gleam`'s `holder`: an
owned seat answers to its account and ignores the guest on it, an unowned
one answers to its guest. Every door asks it (`GameServerState.find_player_id_for/2`,
which the channel's attach, a claim, the record's viewer and `/papi/me/games`
all go through), and `claimable` is false for an owned seat and for a bot seat, so no room
code opens either. The owner rides through the room's memory, `players_json`,
`restore_seats` and `seed_seat`, so a rehydrate and a rematch both keep it.

### The stamp

Signing in hands the account every seat its browser's guest
holds that nobody owns (`Oskol.Auth.adopt_seats/3`, run through
`Oskol.Game.Persister.stamp_seats/3` so it lands *behind* everything the
rooms have queued and cannot race a room rewriting its seats). In the same
transaction the browser's guest row and those seats move to a **fresh guest
id**, which the sign-in response sets as the cookie: the id the browser
arrived with opens nothing afterwards. Rooms that are live are then told
(`GameServer.stamp/4`) so memory agrees with the rows, and a rehydrate
re-reads `players` once after replay in case a stamp landed mid-replay. The
rule itself is one Gleam function (`seat.stamp`) that the row and a room's
memory both call. **An owner never comes off a seat**: every seat-list
write a room makes (a join, a claim, a start) goes through `seat.keep_owners`
against the row, so a room writing from memory that has not heard of a
sign-in yet cannot undo it. The sign-in also drops every socket the browser
opened under its old id (`guest:<old>`), so each tab reconnects on the new
cookie as the account; and if the stamp's transaction rolls back, nothing
moved, so the browser keeps its id and is signed in on that. The guest
cookie is re-set on every page load (the rolling year) but a `/papi`
response writes it only when minting one, so a JSON request that was in
flight during a sign-in cannot answer afterwards and put the old id back. A
seat another account owns is never taken, a seat with no guest (tooling, a
pre-guest row) can never be stamped, and at a table where the account
already owns a seat the browser's other seat is not stamped (one person,
one seat per table, however many devices) but still moves to the fresh
guest id, so that browser keeps playing it as a guest seat. There is
nothing to backfill: every seat starts unowned.

## Signing in (`/papi/auth/*`)

`/papi/auth/*` is signing in, and every one of them is a POST on purpose: a
GET never signs anyone in. A token and its code are sha256 at rest, never
logged, single use, good for 15 minutes; a failed sign-in of any kind
answers one generic sentence. `saved` is how many of this browser's games
came with the account: signing in stamps every unowned seat its guest holds
and rotates that guest id, both in one ordered write, and the response
carries the fresh guest cookie. `next` is validated in Gleam — a local
path, or `/`. Rate limits are in-memory, per-node atomic reservations behind
the auth cap: configurable guest, address, source-IP (per-boot HMAC key only,
and omitted without Fly's trusted header) and global mail budgets. Defaults allow 200 real messages/day per running node
(under Postmark's 10,000-message monthly plan); spent rows and those expired for more than a
day are retired in a supervised bounded sweep at boot and then daily. A failed
pass only logs and retries on the next schedule. There is no switch:
signing in is always on, and prod sends real mail through Postmark. Decisions:
`src/oskol/handlers/auth.gleam`.

## Mail

One mailer (`Oskol.Mailer`, Swoosh over Req) and one mail
(`Oskol.Mail.send_login/3`: the sign-in link, the same sign-in as a
six-digit code, "Both work for 15 minutes"). Prod: `Swoosh.Adapters.Postmark`
on `POSTMARK_TOKEN`, From `POSTMARK_FROM` (default `hello@oskol.io`, sender
name Oskol) on the `POSTMARK_STREAM` message stream (default `outbound`).
Dev: `Swoosh.Adapters.Local` — **read what would have been sent at
`/dev/mailbox`** and click the link out of it; the link and code are logged
too, and `GET /dev/last-login` answers `{link, code, email}` for a browser
test. Both dev routes exist only under `:dev_routes`. Tests:
`Swoosh.Adapters.Test`, read with `assert_receive {:email, mail}`; nothing
ever leaves the process.
