# Playwright scripts

Browser checks and screenshot tours for Oskol. All scripts need a running
server (`mix phx.server`) and take the browser from `PW_CHROMIUM` when
Playwright's own download is unavailable; `bin/check --browser` runs the
smokes for you.

```
playwright/
├── test-backgammon-smoke/   creates a game, stages a move, undoes, plays, with a clock
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

Create `playwright/test-<name>/test.js`. Drive the real lobby: open
`/<slug>`, wait for `[data-phx-main].phx-connected`, fill the name, create
the game, open the share link in a second page. Then act on the Elm game
page through its buttons and assert on the DOM, never on internal state.
Set `BASE_URL` to point at another server.
