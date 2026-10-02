/**
 * Backgammon replay: a finished match played again, with its analysis.
 *
 * The room is arranged by `setup.exs` (a finished match to 3 of several
 * games, found by random play and replayed into a real room). Then:
 *
 * 1. Desktop 1440x900: the replay opens on the match's last game at the
 *    start; the analysis says it is running ("Analyzing game N at 4-ply…")
 *    while `/reviews` answers pending; stepping with the buttons and the
 *    arrow keys moves one line at a time; when the analysis lands (the
 *    page polls) the grades fill in and the viewer stays on the same step;
 *    a candidate move goes on the board and comes off again; OVERVIEW
 *    shows each player's PR and keeps the step; End goes to the last line.
 * 2. A game whose analysis failed says so and offers TRY AGAIN, which
 *    re-asks (a POST) and fills the game in.
 * 3. Polling stops once nothing is pending.
 *    board fits the screen, and a swipe across the board steps.
 *    Everywhere, the side is one panel under one bar of three tabs
 *    (OVERVIEW, MOVE, CUBE): the start opens on OVERVIEW with MOVE and
 *    CUBE greyed, a step opens MOVE, CUBE is offered on a roll only,
 *    OVERVIEW mid-game keeps the step and MOVE comes back to it, each
 *    shows its content alone; on a phone the page scrolls rather than
 *    any panel.
 * 5. The table offers REPLAY at game over, and it opens this page.
 * 6. OPEN IN ANALYSIS (`#rp-analysis`, over the tabs) opens the step's
 *    decision on the analysis board in a new tab: at a graded turn, then
 *    at the first double, the first take, a turn of the Crawford game and
 *    a turn after it, the board's point counts (read from the editor's
 *    targets), the bars, the dice, the cube and its owner, the score and
 *    Crawford are the record's, worked out here from the record's JSON.
 *    A result line keeps the link's place, unseen, and the panel does not
 *    move as the reader steps on and off it.
 * 7. SHARE (`#rp-share-position`, beside OPEN IN ANALYSIS) on the seeded
 *    match at 821900, really graded (`share_setup.exs`; no stub, and no
 *    engine either -- the share is written from the stored answer): at a
 *    graded roll it copies `/puzzles/<id>`; the doors and the panel hold
 *    their boxes at a start, a roll, a double, a result and a game that is
 *    not graded ("Graded soon"); a stranger opening the link plays it and
 *    gets the reveal, under which WATCH THE REPLAY lands back on
 *    `?game=n&step=s`. Screenshots of that page at 390x844 and desktop.
 *
 * The analysis is stubbed by default (`lib/replay-stub.js`): `/reviews`
 * (the index: a status and a turn count per game) and `/reviews/<n>` (one
 * game's analysis) are both answered in the browser, the analysis built
 * from the room's own record (every verdict names a real line of it),
 * pending for the first few asks, then done -- except game 1, which fails
 * until retried. With REPLAY_REAL=1 the real endpoint
 * is used and the script waits for the engine (needs ANALYSIS_URL
 * reachable by the server).
 *
 * Run with the server up:  node playwright/test-backgammon-replay/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');
const { stubAnalysis } = require('../lib/replay-stub');
const { stageATurn } = require('../lib/puzzles');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const SHOTS = process.env.SHOTS_DIR || 'playwright/screenshots/test-backgammon-replay';
const REAL = process.env.REPLAY_REAL === '1';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

function arrangeRoom() {
  if (process.env.REPLAY_JSON) return JSON.parse(process.env.REPLAY_JSON);
  log('arranging a finished match (mix run playwright/test-backgammon-replay/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-replay/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

// ---------- checks ----------

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

async function boardFits(page, what) {
  const b = await page.locator('.bg-still .bg-stack').boundingBox();
  const vp = page.viewportSize();
  must(b.x >= 0 && b.x + b.width <= vp.width + 1, `${what}: the board is within the screen's width`);
  // Whole on screen at once, under the site's bar: the page may scroll (a
  // phone's replay does), so this is the board's height against what the
  // bar leaves, not where a scroll happens to have put it.
  const bar = await page.locator('.lh-bar').boundingBox();
  must(b.height <= vp.height - bar.height + 1, `${what}: the board is within the screen's height, under the bar (${Math.round(b.height)} <= ${vp.height - bar.height})`);
  return b;
}

/** The step counter, once it has settled on `expected` (the board renders
 * on the next frame after a step), or whatever it says after two seconds. */
async function count(page, expected) {
  // The page prints no counter; the row carries the step and the last step
  // as data attributes, read here as the old label read ("START", "4 / 82").
  const read = () => {
    const w = document.querySelector('.rp-controls-wrap');
    const step = Number(w.dataset.step), last = Number(w.dataset.last);
    return step === 0 ? 'START' : `${step} / ${last}`;
  };
  if (expected !== undefined) {
    await page.waitForFunction((want) => {
      const w = document.querySelector('.rp-controls-wrap');
      const step = Number(w.dataset.step), last = Number(w.dataset.last);
      return (step === 0 ? 'START' : `${step} / ${last}`) === want;
    }, expected, { timeout: 2000 }).catch(() => {});
  } else {
    await sleep(100);
  }
  return page.evaluate(read);
}

/** The side is one panel under one bar of three tabs, OVERVIEW, MOVE and
 * CUBE, each showing its content alone; MOVE and CUBE are offered only
 * where they have something to say; OVERVIEW keeps the step. On a phone
 * the page scrolls, never a panel. Leaves the page where it found it. */
async function onePanel(page, what, { phone }) {
  const tabs = ['#rp-tab-overview', '#rp-note-move', '#rp-note-cube'];
  for (const tab of tabs) must(await page.locator(`#rp-panel .rp-tabs ${tab}`).count() === 1, `${what}: the one panel has the tab ${tab}`);
  must(await page.locator('.rp-panel').count() === 1 && await page.locator('.rp-tabs').count() === 1 && await page.locator('.rp-note-tabs').count() === 0, `${what}: one panel, one bar`);
  must(await page.locator('#rp-list, .rp-line').count() === 0, `${what}: no move list`);
  // The start: OVERVIEW, and neither MOVE nor CUBE is a door.
  const step = Number(await page.getAttribute('.rp-controls-wrap', 'data-step'));
  await page.click('#rp-first');
  await page.waitForFunction(() => document.querySelector('.rp-controls-wrap').dataset.step === '0', null, { timeout: 2000 });
  await page.waitForSelector('#rp-overview', { timeout: 2000 });
  must(await page.locator('#rp-tab-overview.is-on').count() === 1, `${what}: the start opens on OVERVIEW`);
  must(await page.locator('#rp-overview #rp-summary .rp-pr').count() === 2, `${what}: the overview is the summary, both PRs`);
  must(await page.locator('#practice-game').count() === 0, `${what}: nothing to press for practice on the overview`);
  must(await page.locator('#rp-note-move:disabled').count() === 1 && await page.locator('#rp-note-cube:disabled').count() === 1, `${what}: MOVE and CUBE are not offered before the first roll`);
  // Back where it was, then on to a roll if that line is not one (the
  // room is random play: a line can be a double, a take, a dance): MOVE
  // is the roll's verdict, CUBE its other side.
  for (let i = 0; i < step; i++) await page.click('#rp-next');
  await page.waitForFunction((want) => document.querySelector('.rp-controls-wrap').dataset.step === String(want), step, { timeout: 2000 });
  for (let i = 0; i < 12 && !(await page.locator('#rp-note-cube:enabled').count() && await page.locator('#rp-note .rp-grade').count()); i++) {
    await page.click('#rp-next');
    await sleep(120);
  }
  const roll = Number(await page.getAttribute('.rp-controls-wrap', 'data-step'));
  await page.waitForSelector('#rp-note-cube:enabled', { timeout: 2000 });
  must(await page.locator('#rp-note-move.is-on').count() === 1 && await page.locator('#rp-panel > #rp-note .rp-grade').count() === 1, `${what}: a step opens MOVE, that move's verdict`);
  await page.click('#rp-note-cube');
  await page.waitForSelector('#rp-note-cube.is-on', { timeout: 2000 });
  must(await page.locator('#rp-panel > #rp-note').count() === 1 && await page.locator('#rp-overview').count() === 0, `${what}: CUBE shows the note alone`);
  // OVERVIEW mid-game keeps the step; MOVE is the way back.
  await page.click('#rp-tab-overview');
  await page.waitForSelector('#rp-overview', { timeout: 2000 });
  must(Number(await page.getAttribute('.rp-controls-wrap', 'data-step')) === roll && await page.locator('#rp-note').count() === 0, `${what}: OVERVIEW mid-game keeps step ${roll} and shows the overview alone`);
  must(await page.locator('.rp-tab.is-on').count() === 1, `${what}: one tab is on`);
  if (phone) {
    // The overview is the tallest: the page, not the panel, is what scrolls.
    const scroll = await page.evaluate(() => ({
      page: document.scrollingElement.scrollHeight > innerHeight,
      panels: [...document.querySelectorAll('.rp-panel, .rp-note, .rp-summary, .rp-overview')].filter((el) => el.scrollHeight > el.clientHeight + 1).length,
    }));
    must(scroll.page, `${what}: the page scrolls`);
    must(scroll.panels === 0, `${what}: no panel scrolls inside itself`);
  }
  await page.click('#rp-note-move');
  await page.waitForSelector('#rp-note-move.is-on', { timeout: 2000 });
  must(Number(await page.getAttribute('.rp-controls-wrap', 'data-step')) === roll && await page.locator('#rp-note .rp-grade').count() === 1, `${what}: MOVE comes back to step ${roll}'s verdict`);
}

// ---------- OPEN IN ANALYSIS ----------

/** The decision at `step` of `game`, worked out from the record's JSON as
 * the analysis board should open it: the board and cube before the step,
 * who is asked, the dice (`00` a double, `D` a take), the score the game
 * began at and Crawford. Null for a step that is no decision. */
function decisionAt(record, game, step) {
  const colorOf = (id) => record.players.find((p) => p.id === id).color;
  let position = record.start;
  let cube = record.start.cube;
  let double = null;
  for (const e of game.entries.slice(0, step - 1)) {
    if (e.kind === "turn") { position = e.position; cube = e.position.cube; }
    if (e.kind === "double") double = e;
    if (e.kind === "take") cube = { value: double.value, owner: e.player };
  }
  const entry = game.entries[step - 1];
  const other = (color) => (color === "white" ? "black" : "white");
  let turn, dice;
  if (entry.kind === "turn") { turn = colorOf(entry.player); dice = [...entry.dice].slice(0, 2).sort((a, b) => b - a).join(""); }
  else if (entry.kind === "double") { turn = colorOf(entry.player); dice = "00"; }
  else if (entry.kind === "take" || entry.kind === "drop") { turn = other(colorOf(entry.player)); dice = "D"; }
  else return null;
  const prior = record.games.filter((g) => g.number < game.number).map((g) => g.entries[g.entries.length - 1]).filter((e) => e && e.kind === "game_over");
  const scores = prior.length ? prior[prior.length - 1].scores : {};
  const scoreOf = (color) => scores[record.players.find((p) => p.color === color).id] || 0;
  return {
    points: position.white.points.map((w, i) => ({ white: w, black: position.black.points[i] })),
    bars: { white: position.white.bar, black: position.black.bar },
    cube: { value: cube.value, owner: cube.owner ? colorOf(cube.owner) : null },
    turn, dice,
    score: { white: scoreOf("white"), black: scoreOf("black") },
    crawford: game.crawford,
  };
}

/** Click OPEN IN ANALYSIS on the replay page as it stands, and check the
 * board that opens in the new tab against `want`. Closes the tab. */
async function openedInAnalysis(context, page, want, what) {
  const link = page.locator("#rp-analysis");
  must(await link.getAttribute("target") === "_blank" && await link.getAttribute("rel") === "noopener", `${what}: OPEN IN ANALYSIS opens a new tab`);
  const [an] = await Promise.all([context.waitForEvent("page"), link.click()]);
  await an.waitForSelector("#an-pt-24", { timeout: 20000 });
  must(/\/analysis\?xgid=/.test(an.url()), `${what}: the new tab is /analysis?xgid=`);
  must(/\/replay/.test(page.url()), `${what}: the replay stays where it was`);
  await an.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  for (let p = 1; p <= 24; p++) {
    const drawn = await an.$eval(`#an-pt-${p}`, (el) => {
      const count = (color) => {
        const label = el.querySelector(`.checker.${color} .checker-count`);
        return label ? Number(label.textContent) : el.querySelectorAll(`.checker.${color}`).length;
      };
      return { white: count("white"), black: count("black") };
    });
    const w = want.points[p - 1];
    if (drawn.white !== w.white || drawn.black !== w.black)
      throw new Error(`${what}: point ${p} draws ${JSON.stringify(drawn)}, the replay has ${JSON.stringify(w)}`);
  }
  log(`ok: ${what}: all 24 points draw the replay's checkers`);
  const id = await an.inputValue("#an-xgid");
  const f = id.slice(5).split(":");
  const at = (i) => { const ch = f[0][i]; return ch === "-" ? 0 : ch >= "A" && ch <= "P" ? ch.charCodeAt(0) - 64 : -(ch.charCodeAt(0) - 96); };
  const got = {
    bars: { white: at(25), black: -at(0) },
    cube: { value: 2 ** Number(f[1]), owner: { "0": null, "1": "white", "-1": "black" }[f[2]] },
    turn: { "1": "white", "-1": "black" }[f[3]],
    dice: f[4],
    score: { white: Number(f[5]), black: Number(f[6]) },
    crawford: f[7] === "1",
    length: Number(f[8]),
  };
  const expected = { bars: want.bars, cube: want.cube, turn: want.turn, dice: want.dice, score: want.score, crawford: want.crawford, length: 3 };
  must(JSON.stringify(got) === JSON.stringify(expected), `${what}: bars, cube, owner, turn, dice, score and Crawford are the replay's (${id})`);
  return an;
}

async function swipe(page, dx) {
  await page.evaluate((dx) => {
    const el = document.getElementById('rp-board');
    const r = el.getBoundingClientRect();
    const y = r.top + r.height / 2;
    const x0 = r.left + r.width / 2 - dx / 2;
    const touch = (x) => new Touch({ identifier: 1, target: el, clientX: x, clientY: y });
    el.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, touches: [touch(x0)], changedTouches: [touch(x0)] }));
    el.dispatchEvent(new TouchEvent('touchend', { bubbles: true, touches: [], changedTouches: [touch(x0 + dx)] }));
  }, dx);
  await sleep(250);
}

async function main() {
  const room = arrangeRoom();
  const alice = room.players[0];
  fs.mkdirSync(SHOTS, { recursive: true });
  // A replay link carries no credential: it is the room's plain URL. Alice's
  // own browser is told the record is hers because of her guest cookie, set
  // on the contexts below.
  const url = (extra = '') => `${BASE}/backgammon/${room.game_id}/replay${extra.replace(/^&/, '?')}`;
  const asAlice = async (context) => {
    await context.addCookies([
      { name: '_oskol_guest', value: alice.guest, url: BASE, httpOnly: true, sameSite: 'Lax' },
    ]);
    return context;
  };

  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    // The record as the page reads it, for the stub to build on.
    const api = await playwright.request.newContext({
      extraHTTPHeaders: { cookie: `_oskol_guest=${alice.guest}` },
    });
    const res = await api.get(`${BASE}/papi/games/backgammon/rooms/${room.game_id}/record`);
    const recordBody = await res.json();
    must(recordBody.ok && recordBody.you === alice.id && recordBody.seated,
      "the record names the reader's own seat, from their guest cookie");
    const record = recordBody.record;
    must(record.games.length > 1 && record.start && record.cube === true, `the record has ${record.games.length} games, a start position and a cube`);
    const last = record.games[record.games.length - 1];
    log(`room ${room.game_id}: ${record.games.length} games, the last ${last.entries.length} lines (analysis ${REAL ? 'REAL' : 'stubbed'})`);

    // ---------- 1. desktop ----------
    const desktop = await asAlice(await browser.newContext({ viewport: { width: 1440, height: 900 } }));
    await desktop.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const counts = { get: 0, retry: 0, game: 0 };
    if (!REAL) await stubAnalysis(desktop, record, counts);
    const page = await desktop.newPage();
    watch(page, 'desktop');
    await page.goto(url());
    await page.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
    must((await count(page)) === 'START', 'the replay opens at the start of a game');
    // The match panel (under the board, between the arrows) marks the game on the board.
    await page.click('#rp-match');
    await page.waitForSelector('#bg-match-sheet');
    must(await page.locator(`.rp-match-row[data-game="${last.number}"].is-on`).count() === 1, `it opens the match's last game (${last.number})`);
    await page.click('#bg-match-close');
    await page.waitForSelector('#bg-match-sheet', { state: 'detached' });
    if (!REAL) {
      await page.waitForSelector('#rp-analysis-state.is-pending', { timeout: 5000 });
      must(/Analyzing game \d+ at 4-ply… this can take a few minutes/.test(await page.textContent('#rp-analysis-state')), 'a pending analysis says so, and that it takes a while');
      await page.screenshot({ path: `${SHOTS}/01-desktop-pending.png` });
    }

    await page.click('#rp-next');
    await page.click('#rp-next');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowRight');
    await page.keyboard.press('ArrowLeft');
    { const c = await count(page, `4 / ${last.entries.length}`); must(c === `4 / ${last.entries.length}`, `buttons and arrow keys step one line at a time (${c})`); }
    // The room is random play: line 4 may be a turn, a dance or a cube line.
    const fourth = last.entries[3];
    const landed = await page.locator('.bg-still .checker.just-moved').count();
    if (fourth.kind === 'turn' && fourth.landed.length > 0) must(landed > 0, `a turn marks the checkers it landed (${landed})`);
    else must(landed === 0, `a line that landed nothing (${fourth.kind}) marks nothing`);

    // The analysis lands while the viewer is on step 4.
    await page.waitForSelector('#rp-note .rp-grade', { timeout: REAL ? 180000 : 15000 });
    must((await count(page, `4 / ${last.entries.length}`)) === `4 / ${last.entries.length}`, 'the grades fill in without moving the viewer');

    // Find a turn that was not the engine's best, and put its best on the board.
    let found = false;
    for (let i = 0; i < last.entries.length && !found; i++) {
      await sleep(60);
      if (await page.locator('.rp-cand:not(.is-played)').count() > 0) { found = true; break; }
      await page.keyboard.press('ArrowRight');
    }
    must(found, 'some turn has a better move to show');
    const before = await page.locator('.bg-still').innerHTML();
    await page.click('.rp-cand:not(.is-played)');
    await page.waitForSelector('.rp-board.is-proposed');
    must((await page.locator('.bg-still').innerHTML()) !== before, 'a proposed move is drawn on the board');
    await page.screenshot({ path: `${SHOTS}/02-desktop-best-move.png` });
    await page.click('.rp-cand.is-played');
    await page.waitForSelector('.rp-board.is-proposed', { state: 'detached', timeout: 2000 }).catch(() => {});
    must(await page.locator('.rp-board.is-proposed').count() === 0, 'and the played move comes back');
    await page.screenshot({ path: `${SHOTS}/03-desktop-graded.png` });

    // ---------- 6. OPEN IN ANALYSIS, at the graded turn ----------
    {
      const graded = Number(await page.getAttribute('.rp-controls-wrap', 'data-step'));
      const want = decisionAt(record, last, graded);
      must(want && last.entries[graded - 1].kind === 'turn', `step ${graded} of game ${last.number} is a graded turn`);
      const an = await openedInAnalysis(desktop, page, want, `graded turn (game ${last.number}, step ${graded})`);
      await an.screenshot({ path: `${SHOTS}/07-analysis-from-replay.png` });
      await an.close();
    }

    await page.click('#rp-tab-overview');
    await page.waitForSelector('#rp-overview .rp-pr');
    must(await page.locator('#rp-overview .rp-pr').count() === 2, 'the overview gives both players a PR');
    await page.screenshot({ path: `${SHOTS}/04-desktop-summary.png` });
    await onePanel(page, 'desktop', { phone: false });

    await page.keyboard.press('End');
    must((await count(page, `${last.entries.length} / ${last.entries.length}`)) === `${last.entries.length} / ${last.entries.length}`, 'End goes to the last line');

    // ---------- 2. a failed game, tried again ----------
    if (!REAL) {
      await page.click('#rp-match');
      await page.click('.rp-match-row[data-game="1"]');
      await page.waitForSelector('#rp-analysis-state.is-failed');
      must(await page.locator('#rp-retry').count() === 1, 'a failed analysis offers to try again');
      await page.screenshot({ path: `${SHOTS}/05-desktop-failed.png` });
      await page.click('#rp-retry');
      await page.waitForFunction(() => !document.querySelector('#rp-analysis-state.is-failed'), null, { timeout: 5000 });
      must(counts.retry === 1, 'TRY AGAIN asked the server once');

      // ---------- 3. polling stops ----------
      const asked = counts.get;
      await sleep(7000);
      must(counts.get === asked, `nothing pending: no more asks (${asked} in all)`);
    }
    // ---------- 6. OPEN IN ANALYSIS, at every kind of step ----------
    {
      const find = (pick) => {
        for (const g of record.games) for (let s = 1; s <= g.entries.length; s++) if (pick(g, g.entries[s - 1])) return { g, s };
        return null;
      };
      const crawfordAt = record.games.findIndex((g) => g.crawford);
      must(crawfordAt > 0 && record.games.filter((g) => g.crawford).length === 1, `the record marks one game, game ${crawfordAt + 1}, as the Crawford game`);
      const cases = [
        ['a double', find((g, e) => e.kind === 'double')],
        ['a take', find((g, e) => e.kind === 'take')],
        ['a turn of the Crawford game', find((g, e) => g.crawford && e.kind === 'turn')],
        ['a turn after the Crawford game', find((g, e) => g.number > record.games[crawfordAt].number && e.kind === 'turn')],
      ];
      for (const [what, at] of cases) {
        must(at !== null, `the match has ${what}`);
        await page.goto(url(`&game=${at.g.number}&step=${at.s}`));
        await page.waitForSelector('#rp-analysis[href]', { timeout: 20000 });
        const an = await openedInAnalysis(desktop, page, decisionAt(record, at.g, at.s), `${what} (game ${at.g.number}, step ${at.s})`);
        await an.close();
      }
      // A result line is no decision: the link keeps its place, unseen, and
      // stepping on and off it moves nothing in the panel.
      const g = record.games[0];
      await page.goto(url(`&game=${g.number}&step=${g.entries.length - 1}`));
      await page.waitForSelector('#rp-analysis[href]', { timeout: 20000 });
      const box = async () => JSON.stringify(await Promise.all(['#rp-analysis', '#rp-tabs', '#rp-panel'].map((sel) => page.locator(sel).boundingBox())));
      const on = await box();
      await page.click('#rp-next');
      await page.waitForSelector('#rp-analysis.is-off', { state: 'attached', timeout: 2000 });
      must(await page.locator('#rp-analysis').isVisible() === false && await page.locator('a#rp-analysis').count() === 0, 'a result line has no door to the analysis board');
      must(await box() === on, 'and the link, the tabs and the panel stay where they were');
    }
    await page.close();
    await desktop.close();

    // ---------- 4. phones ----------
    for (const phone of [
      { name: 'phone', width: 390, height: 844 },
      { name: 'phone-small', width: 320, height: 568 },
      { name: 'landscape', width: 844, height: 390 },
    ]) {
      const ctx = await asAlice(await browser.newContext({ viewport: { width: phone.width, height: phone.height }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }));
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      if (!REAL) await stubAnalysis(ctx, record, { get: 5, retry: 0 });
      const p = await ctx.newPage();
      watch(p, phone.name);
      await p.goto(url(`&game=${last.number}`));
      await p.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
      await p.waitForSelector('#rp-panel', { timeout: 20000 });
      await sleep(REAL ? 3000 : 500);
      await swipe(p, -120);
      await swipe(p, -120);
      await swipe(p, -120);
      must((await count(p, `3 / ${last.entries.length}`)) === `3 / ${last.entries.length}`, `${phone.name}: a swipe left steps forward`);
      await swipe(p, 120);
      must((await count(p, `2 / ${last.entries.length}`)) === `2 / ${last.entries.length}`, `${phone.name}: a swipe right steps back`);
      await swipe(p, 10);
      must((await count(p)) === `2 / ${last.entries.length}`, `${phone.name}: a short touch is not a step`);
      for (let i = 0; i < 8; i++) await p.click('#rp-next');
      await sleep(400);
      await noSideways(p, phone.name);
      for (const control of ['#rp-first', '#rp-last']) {
        const b = await p.locator(control).boundingBox();
        must(b.x >= 0 && b.x + b.width <= phone.width + 1, `${phone.name}: ${control} is inside the screen`);
      }
      const board = await boardFits(p, phone.name);
      if (phone.name === 'landscape') {
        const side = await p.locator('.rp-side').boundingBox();
        must(side.x >= board.x + board.width - 1, 'landscape: the notes sit beside the board, not on it');
      }
      await onePanel(p, phone.name, { phone: true });
      await p.screenshot({ path: `${SHOTS}/06-${phone.name}.png` });
      await ctx.close();
    }

    // ---------- 5. the table's door ----------
    const table = await asAlice(await browser.newContext({ viewport: { width: 1280, height: 860 } }));
    await table.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    if (!REAL) await stubAnalysis(table, record, { get: 5, retry: 0 });
    const t = await table.newPage();
    watch(t, 'table');
    await t.goto(`${BASE}/backgammon/${room.game_id}`);
    await t.waitForSelector('#bg-replay', { timeout: 20000 });
    await t.click('#bg-replay');
    await t.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
    must(/\/replay\?game=\d+$/.test(t.url()), 'REPLAY at game over opens this game\'s replay, with no token in the link');
    await table.close();

    await sharePosition(browser, watch);

    must(errors.length === 0, `no page errors${errors.length ? ': ' + errors.join(' | ') : ''}`);
    log('all replay checks passed');
  } finally {
    await browser.close();
  }
}

// ---------- 7. SHARE POSITION ----------

async function sharePosition(browser, watch) {
  log('arranging the seeded match (mix run playwright/test-backgammon-replay/share_setup.exs)');
  const room = JSON.parse(resultLine(execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-replay/share_setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  )));
  const code = room.game_id;
  const record = await (await fetch(`${BASE}/papi/games/backgammon/rooms/${code}/record`)).json();
  const game1 = record.record.games.find((g) => g.number === 1);
  const at = (kind) => game1.entries.findIndex((e) => e.kind === kind) + 1;
  // Game 1's second roll: a checker play with plenty of ways to play it.
  const rollStep = 2;
  const replayAt = (game, step) => `${BASE}/backgammon/${code}/replay?game=${game}&step=${step}`;

  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: BASE });
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  // The last game is told it is still being graded, in the browser only:
  // what a game whose review has not landed looks like.
  await ctx.route(new RegExp(`/papi/games/backgammon/rooms/${code}/reviews$`), async (route) => {
    const res = await route.fetch();
    const body = await res.json();
    const last = body.games[body.games.length - 1];
    last.status = 'pending';
    await route.fulfill({ response: res, json: body });
  });
  const page = await ctx.newPage();
  watch(page, 'share');
  const lastGame = record.record.games[record.record.games.length - 1].number;
  // Where the doors and the tabs sit within the panel, and the panel's
  // size: a page loaded on another step may put the panel elsewhere on the
  // screen (a verdict over the board), but nothing inside it may move.
  const boxes = async () => {
    const [panel, ...rest] = await Promise.all(['#rp-panel', '#rp-share-position', '#rp-analysis', '#rp-tabs'].map((sel) => page.locator(sel).boundingBox()));
    return JSON.stringify([Math.round(panel.width), ...rest.map((r) => [r.x - panel.x, r.y - panel.y, r.width, r.height].map(Math.round))]);
  };
  await page.goto(replayAt(1, rollStep));
  await page.waitForSelector('button#rp-share-position:not(.is-soon)', { timeout: 20000 });
  const on = await boxes();
  for (const [what, game, step, state] of [
    ['the start', 1, 0, 'off'],
    ['the first double', 1, at('double'), 'ready'],
    ['the result', 1, game1.entries.length, 'off'],
    ['a roll of a game not graded yet', lastGame, 2, 'soon'],
  ]) {
    await page.goto(replayAt(game, step));
    await page.waitForSelector('#rp-panel', { timeout: 20000 });
    const sel = { off: '#rp-share-position.is-off', ready: 'button#rp-share-position:not(.is-soon)', soon: 'button#rp-share-position.is-soon' }[state];
    await page.waitForSelector(sel, { state: 'attached', timeout: 20000 });
    must(await boxes() === on, `${what}: SHARE is ${state}, and the doors, the tabs and the panel hold their boxes`);
    if (state === 'soon') {
      must(await page.isVisible('#rp-share-soon'), `${what}: "Graded soon" says so beside it`);
      // aria-disabled, which a pointer still presses.
      await page.click('#rp-share-position', { force: true });
      await page.waitForSelector('#rp-share-note');
      must((await page.textContent('#rp-share-note')).includes('shareable once the game is graded'), `${what}: pressed, it says why, and asks nobody`);
      must(await boxes() === on, `${what}: the line floats, and moves nothing`);
    }
  }

  await page.goto(replayAt(1, rollStep));
  await page.waitForSelector('button#rp-share-position:not(.is-soon)', { timeout: 20000 });
  await page.click('#rp-share-position');
  await page.waitForSelector('#rp-share-note', { timeout: 10000 });
  must((await page.textContent('#rp-share-note')).trim() === 'Link copied', 'SHARE copies the link, and says so');
  must(await boxes() === on, 'and nothing moved');
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  must(new RegExp(`^${BASE}/puzzles/[A-Za-z0-9]+$`).test(copied), `the link is the puzzle's own: ${copied}`);
  await page.screenshot({ path: `${SHOTS}/07-share-copied.png` });
  await ctx.close();

  // A stranger with the link: the ordinary puzzle page, then the way back.
  for (const vp of [{ name: 'desktop', width: 1440, height: 900 }, { name: 'phone', width: 390, height: 844, mobile: true }]) {
    const sctx = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, isMobile: !!vp.mobile, hasTouch: !!vp.mobile, deviceScaleFactor: 2 });
    await sctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const p = await sctx.newPage();
    watch(p, `shared-${vp.name}`);
    await p.goto(copied);
    await p.waitForSelector('#pz-prompt, .pz-prompt', { timeout: 20000 }).catch(() => {});
    must(/What's your play\?/.test(await p.title()), `${vp.name}: the page asks the question, naming nobody`);
    must(!(await p.isVisible('#pz-replay')), `${vp.name}: no way back before the attempt`);
    await stageATurn(p);
    await p.click('#bg-action-play');
    await p.waitForSelector('#pz-reveal');
    await p.waitForSelector('#pz-replay');
    must((await p.textContent('#pz-from-replay')).includes('From a game on Oskol'), `${vp.name}: the reveal says where it came from`);
    await p.locator('#pz-replay').scrollIntoViewIfNeeded();
    await p.screenshot({ path: `${SHOTS}/07-shared-${vp.name}.png` });
    await p.click('#pz-replay');
    await p.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
    must(p.url().endsWith(`/backgammon/${code}/replay?game=1&step=${rollStep}`), `${vp.name}: WATCH THE REPLAY lands on the very step (${p.url()})`);
    const landed = await p.waitForFunction((want) => document.querySelector('.rp-controls-wrap')?.dataset.step === want, String(rollStep), { timeout: 5000 }).then(() => true, () => false);
    must(landed, `${vp.name}: and the replay shows it`);
    await sctx.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
