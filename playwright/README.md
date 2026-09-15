# Playwright scripts

Browser checks and screenshot tours for Oskol. All scripts need a running
server (`mix phx.server`) and take the browser from `PW_CHROMIUM` when
Playwright's own download is unavailable; `bin/check --browser` runs the
smokes for you.

```
playwright/
├── lib/flows.js            create a game, join by link or code, open a seat
├── test-backgammon-smoke/   creates a game, stages a move, plays, with a clock
├── review-pages/            screenshots of the library, start pages and lobby (desktop + phone)
├── review-games/            screenshots of games in play (desktop + phone)
└── screenshots/             output of the review scripts
```

```bash
node playwright/test-backgammon-smoke/test.js
node playwright/review-pages/test.js
node playwright/review-games/test.js
```

Each smoke logs its steps and exits non-zero on failure. The review scripts
are for eyeballing; look at `playwright/screenshots/`.

## Writing a new smoke

Create `playwright/test-<name>/test.js`. Get into a game through
`playwright/lib/flows.js` rather than clicking through the pages yourself:
`createGame(page, {name, mode, clock, twist})` goes to `/`, presses CREATE
GAME, fills the dialog by id and resolves with `{gameId, url, inviteUrl}`;
`joinByLink(page, inviteUrl, name)` and `joinByCode(page, code, name)` take
the second seat; `openSeat(page, url)` reopens one. Then act on the Elm game
page through its buttons and assert on the DOM, never on internal state.
Set `BASE_URL` (or `PORT`) to point at another server.
