/**
 * The Analysis milestone, shot whole for a review: every state of the
 * analysis board, and the doors onto it and out of it, at 390x844,
 * 320x568, 844x390 and 1440x900.
 *
 *   01-menu        the empty board (CLEAR) with ☰ open on Analysis
 *   02-building    a position half set up, the brushes over it
 *   03-rolls       the roll sheet
 *   04-black-to-play  Black to play: TO PLAY, and Black's bar the one to move
 *   05-move        the answer for a move (the opening 3-1)
 *   06-candidate   the engine's #2 on the board (06b, sideways: scrolled to
 *                  the answer, the board still in view)
 *   07-cube        the answer for a cube (DOUBLE? at the opening)
 *   08-line        a line of three steps, in PLAY: the strip locked, the
 *                  table on a picked roll
 *   09-save        the save sheet for an account, "Openings I like" ticked
 *   10-save-guest  the save sheet for a guest: sign in to keep it
 *   11-hub         /puzzles: the five, then "Your sets"
 *   12-set         the set's page with MANAGE
 *   13-replay      the replay's head: OPEN IN ANALYSIS and SHARE
 *   14-shared      a position shared from the replay, played to the
 *                  reveal: SAVE, OPEN IN ANALYSIS, WATCH THE REPLAY
 *
 * into playwright/screenshots/review-analysis-<tag>-<state>.png.
 *
 * It arranges everything itself on whatever database the server uses
 * (setup.exs: the seeded match at 821900, the universal sets, an account)
 * and starts the analysis board's stand-in engine
 * (`test-analysis/setup.exs`, on ANALYSIS_STUB_PORT, PORT + 10000 unless
 * named), so the server's ANALYSIS_URL must point there. run.sh does all of
 * it on its own port and database:
 *
 *   playwright/review-analysis/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { spawn, execSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { stageATurn } = require('../lib/puzzles');

const SHOTS = 'playwright/screenshots';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const STUB_PORT = Number(process.env.ANALYSIS_STUB_PORT || Number(new URL(BASE).port || 80) + 10000);

const OPENING_31 = 'XGID=-b----E-C---eE---c-e----B-:0:0:1:31:0:0:1:0:10';
// The opening with nobody on roll yet: White may double.
const OPENING_CUBE = 'XGID=-b----E-C---eE---c-e----B-:0:0:1:00:0:0:1:0:10';

const SIZES = [
  ['390', { width: 390, height: 844 }, true],
  ['320', { width: 320, height: 568 }, true],
  ['844x390', { width: 844, height: 390 }, true],
  ['desktop', { width: 1440, height: 900 }, false],
];

const settle = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));

function watch(page, who, errors) {
  page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
  });
}

async function shot(page, name, { full = true } = {}) {
  await settle(page);
  if (full) await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(250);
  await page.screenshot({ path: `${SHOTS}/review-analysis-${name}.png`, fullPage: full });
}

async function noSideScroll(page, tag) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (wide > 0) throw new Error(`${tag}: the page scrolls ${wide}px sideways`);
}

/** The stand-in engine, listening, and a way to stop it. */
async function startEngine() {
  log(`starting the stand-in engine on ${STUB_PORT} (test-analysis/setup.exs)`);
  const child = spawn('mix', ['run', '--no-start', '-e', 'Code.eval_file("playwright/test-analysis/setup.exs")'], {
    env: { ...process.env, ANALYSIS_STUB_PORT: String(STUB_PORT), MIX_ENV: process.env.MIX_ENV || 'dev' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const stop = () => { try { child.stdin.end(); } catch (_) {} try { child.kill(); } catch (_) {} };
  process.on('exit', stop);
  await new Promise((resolve, reject) => {
    let out = '';
    child.stdout.on('data', (d) => {
      out += d;
      try { resultLine(out); resolve(); } catch (_) {}
    });
    child.on('exit', (code) => reject(new Error(`the stand-in engine stopped (${code}):\n${out.slice(-2000)}`)));
  });
  return stop;
}

async function context(browser, viewport, touch, guestId) {
  const options = { viewport, hasTouch: touch, isMobile: touch };
  const ctx = guestId ? await seatedContext(browser, guestId, options) : await browser.newContext(options);
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  return ctx;
}

function presser(page, touch) {
  return async (target) => {
    const loc = typeof target === 'string' ? page.locator(target) : target;
    await (touch ? loc.tap() : loc.click());
    await settle(page);
  };
}

async function open(page, path) {
  await page.goto(`${BASE}${path}`);
  await page.waitForSelector('#an-pt-24');
  await settle(page);
}

const board = (xgid) => `/analysis?xgid=${encodeURIComponent(xgid)}`;

async function analyze(page, press) {
  await press('#an-analyze');
  await page.waitForSelector('#an-answer', { timeout: 30000 });
  await settle(page);
}

/** A JSON call from the page, as the client makes it (the CSRF token). */
async function call(page, method, path, body) {
  return page.evaluate(async ([m, p, b]) => {
    const token = document.querySelector("meta[name='csrf-token']").getAttribute('content');
    const res = await fetch(p, {
      method: m,
      headers: { 'content-type': 'application/json', 'x-csrf-token': token },
      body: b === undefined ? undefined : JSON.stringify(b),
    });
    return { status: res.status, body: await res.json() };
  }, [method, path, body]);
}

// ---------- the account's set ----------

/** "Openings I like": the opening 3-1 and the opening's cube, made the way
 * the save sheet makes it (its own API), each answered first. */
async function makeTheSet(browser, fixture, errors) {
  const ctx = await context(browser, { width: 1440, height: 900 }, false, fixture.guest_id);
  try {
    const page = await ctx.newPage();
    watch(page, 'arrange', errors);
    const press = presser(page, false);
    const ids = [];
    for (const xgid of [OPENING_31, OPENING_CUBE]) {
      await open(page, board(xgid));
      if (xgid === OPENING_CUBE) await press('#an-ask-double');
      await analyze(page, press);
      ids.push((await page.getAttribute('#an-open-puzzle', 'href')).replace('/puzzles/', ''));
    }
    const made = await call(page, 'POST', '/papi/decks/mine', { name: 'Openings I like' });
    if (made.status !== 200) throw new Error(`making the set: ${made.status} ${JSON.stringify(made.body)}`);
    const setId = made.body.deck.id;
    for (const id of ids) {
      const added = await call(page, 'POST', `/papi/decks/${setId}/puzzles`, { puzzle_id: id });
      if (added.status !== 200) throw new Error(`saving ${id}: ${added.status} ${JSON.stringify(added.body)}`);
    }
    log(`"Openings I like" (${setId}) holds ${ids.join(', ')}`);
    return setId;
  } finally {
    await ctx.close();
  }
}

/** The replay's game 1, step 2 (a checker play), shared: its puzzle link. */
async function sharedLink(browser, room, errors) {
  const ctx = await context(browser, { width: 1440, height: 900 }, false);
  try {
    const page = await ctx.newPage();
    watch(page, 'share', errors);
    await page.goto(`${BASE}/backgammon/${room}/replay?game=1&step=2`);
    await page.waitForSelector('button#rp-share-position:not(.is-soon)', { timeout: 20000 });
    const res = await call(page, 'POST', `/papi/games/backgammon/rooms/${room}/positions`, { game: 1, step: 2 });
    if (res.status !== 200) throw new Error(`sharing the step: ${res.status} ${JSON.stringify(res.body)}`);
    return res.body.url;
  } finally {
    await ctx.close();
  }
}

// ---------- the board ----------

async function theBoard(browser, tag, viewport, touch, errors) {
  const ctx = await context(browser, viewport, touch);
  try {
    const page = await ctx.newPage();
    watch(page, `board ${tag}`, errors);
    const press = presser(page, touch);

    // 01: empty, ☰ open on Analysis.
    await open(page, '/analysis');
    await press('#an-clear');
    await page.evaluate(() => window.scrollTo(0, 0));
    await press('#nav-more');
    await page.waitForSelector('#nav-menu #nav-analysis');
    await shot(page, `${tag}-01-menu`, { full: false });

    // 02: half set up. White's back checkers and midpoint, Black's too,
    // painted with the brushes; White's 8 and 6 points still to come.
    await open(page, '/analysis');
    await press('#an-clear');
    await press('#an-brush-white');
    for (const [pt, n] of [[24, 2], [13, 5]]) for (let i = 0; i < n; i++) await press(`#an-pt-${pt}`);
    await press('#an-brush-black');
    for (const [pt, n] of [[1, 2], [12, 5], [17, 3], [19, 5]]) for (let i = 0; i < n; i++) await press(`#an-pt-${pt}`);
    await press('#an-brush-white');
    await noSideScroll(page, `${tag} building`);
    await shot(page, `${tag}-02-building`);

    // 03: the roll sheet.
    await open(page, '/analysis');
    await press('#an-dice');
    await page.waitForSelector('#an-roll-sheet');
    await shot(page, `${tag}-03-rolls`, { full: false });
    await press('#an-roll-42');
    await page.waitForSelector('#an-roll-sheet', { state: 'detached' });

    // 04: Black to play: TO PLAY says it, Black's bar is the one to move.
    await press('#an-turn-black');
    await shot(page, `${tag}-04-black-to-play`, { full: false });

    // 05, 06: a move's answer, then the engine's #2 on the board.
    await open(page, board(OPENING_31));
    await analyze(page, press);
    await noSideScroll(page, `${tag} the answer`);
    await shot(page, `${tag}-05-move`);
    await press('#an-candidates .rp-cand[data-rank="2"]');
    await shot(page, `${tag}-06-candidate`);
    if (tag === '844x390') {
      // Sideways the answer is under the fold: scrolled to it, the board
      // stays in view beside it.
      await page.locator('#an-candidates').scrollIntoViewIfNeeded();
      const top = await page.$eval('#an-board', (el) => el.getBoundingClientRect().top);
      if (top < 0) throw new Error(`${tag}: scrolled to the answer, the board is off the screen (${top})`);
      await shot(page, `${tag}-06b-scrolled`, { full: false });
    }
    await press('#an-dice-toggle');

    // 07: the cube's answer.
    await press('#an-ask-double');
    await analyze(page, press);
    await shot(page, `${tag}-07-cube`);

    // 08: a line of three steps in PLAY: White's best 3-1, Black's 6-2
    // played by hand, and White's roll picked from the sheet.
    await open(page, board(OPENING_31));
    await analyze(page, press);
    await press('#an-play-candidate');
    await press('#an-roll-pick');
    await page.waitForSelector('#an-roll-sheet');
    await press('#an-roll-62');
    await stageATurn(page);
    await press('#bg-action-play');
    await page.waitForFunction(() => document.querySelectorAll('#an-plates .an-plate').length === 3);
    await press('#an-roll-pick');
    await page.waitForSelector('#an-roll-sheet');
    await press('#an-roll-55');
    await page.waitForSelector('.bg-point.source, [data-move-source]', { timeout: 15000 });
    const plates = await page.$$eval('#an-plates .an-plate', (ps) => ps.map((p) => p.textContent.trim()));
    if (plates.length !== 3) throw new Error(`${tag}: the line is ${JSON.stringify(plates)}`);
    if (!(await page.$('fieldset#an-strip:disabled'))) throw new Error(`${tag}: the strip is live in PLAY`);
    await noSideScroll(page, `${tag} the line`);
    await shot(page, `${tag}-08-line`);
    log(`${tag}: the board, the sheet, Black to play, a move, a candidate, the cube, the line ${plates.join(' | ')}`);
  } finally {
    await ctx.close();
  }
}

// ---------- saving, the hub, the set ----------

async function theSets(browser, tag, viewport, touch, fixture, setId, errors) {
  const ctx = await context(browser, viewport, touch, fixture.guest_id);
  try {
    const page = await ctx.newPage();
    watch(page, `sets ${tag}`, errors);
    const press = presser(page, touch);

    await open(page, board(OPENING_31));
    await analyze(page, press);
    await press('#an-save');
    await page.waitForSelector(`#save-set-${setId}[aria-checked="true"]`);
    await shot(page, `${tag}-09-save`, { full: false });
    await press('#save-close');

    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-your-sets');
    await page.waitForTimeout(700); // a drawer's slide
    await noSideScroll(page, `${tag} the hub`);
    await shot(page, `${tag}-11-hub`);

    await page.goto(`${BASE}/practice/${setId}`);
    await page.waitForSelector('#practice-manage .dp-member');
    await noSideScroll(page, `${tag} the set`);
    await shot(page, `${tag}-12-set`);
  } finally {
    await ctx.close();
  }

  const guest = await context(browser, viewport, touch);
  try {
    const page = await guest.newPage();
    watch(page, `guest ${tag}`, errors);
    const press = presser(page, touch);
    await open(page, board(OPENING_31));
    await analyze(page, press);
    await press('#an-save');
    await page.waitForSelector('#save-modal #signin-email');
    await shot(page, `${tag}-10-save-guest`, { full: false });
  } finally {
    await guest.close();
  }
  log(`${tag}: the save sheet (an account, a guest), the hub with "Your sets", the set's page`);
}

// ---------- the replay, and a position shared from it ----------

async function theReplay(browser, tag, viewport, touch, room, link, errors) {
  const ctx = await context(browser, viewport, touch);
  try {
    const page = await ctx.newPage();
    watch(page, `replay ${tag}`, errors);
    const press = presser(page, touch);

    await page.goto(`${BASE}/backgammon/${room}/replay?game=1&step=2`);
    await page.waitForSelector('button#rp-share-position:not(.is-soon)', { timeout: 20000 });
    await page.waitForSelector('a#rp-analysis');
    await noSideScroll(page, `${tag} the replay`);
    await shot(page, `${tag}-13-replay`, { full: false });

    await page.goto(`${BASE}${link}`);
    await stageATurn(page);
    await press('#bg-action-play');
    await page.waitForSelector('#pz-reveal');
    await page.waitForSelector('#pz-replay');
    for (const sel of ['#pz-save', '#pz-analysis', '#pz-replay']) {
      if (!(await page.isVisible(sel))) throw new Error(`${tag}: the reveal has no ${sel}`);
    }
    // SHARE, SAVE and ANALYSIS on one row, one height, at every size.
    const row = await page.$$eval('#pz-share, #pz-save, #pz-analysis', (els) => els.map((e) => {
      const r = e.getBoundingClientRect();
      return [Math.round(r.top), Math.round(r.height), e.scrollWidth <= e.clientWidth];
    }));
    if (row.length !== 3 || new Set(row.map((r) => r[0])).size !== 1 || row.some((r) => r[1] !== 32 || !r[2]))
      throw new Error(`${tag}: the reveal's three buttons are not one row of 32px, whole: ${JSON.stringify(row)}`);
    // The sentence names the badge's grade.
    const band = await page.getAttribute('#pz-verdict', 'data-band');
    const verdict = (await page.innerText('#pz-verdict .pz-verdict-why')).trim();
    const word = { doubtful: 'a dubious mistake', bad: 'a bad mistake', very_bad: 'a very bad mistake' }[band];
    if (word && !verdict.includes(word)) throw new Error(`${tag}: the badge is ${band} and the sentence says "${verdict}"`);
    await noSideScroll(page, `${tag} the shared reveal`);
    if (tag === '844x390') {
      // Sideways the reveal scrolls in its own column: down to the way back.
      await page.locator('#pz-replay').scrollIntoViewIfNeeded();
      await shot(page, `${tag}-14-shared`, { full: false });
    } else {
      await shot(page, `${tag}-14-shared`);
    }
  } finally {
    await ctx.close();
  }
  log(`${tag}: the replay's two doors, and the shared reveal's three`);
}

(async () => {
  fs.mkdirSync(SHOTS, { recursive: true });
  log('arranging (mix run playwright/review-analysis/setup.exs)');
  const fixture = JSON.parse(resultLine(execSync(
    `mix run -e 'Code.eval_file("playwright/review-analysis/setup.exs")'`,
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], maxBuffer: 64 * 1024 * 1024 }
  )));
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const errors = [];
  const stopEngine = await startEngine();
  try {
    const setId = await makeTheSet(browser, fixture, errors);
    const link = await sharedLink(browser, fixture.room, errors);
    for (const [tag, viewport, touch] of SIZES) {
      await theBoard(browser, tag, viewport, touch, errors);
      await theSets(browser, tag, viewport, touch, fixture, setId, errors);
      await theReplay(browser, tag, viewport, touch, fixture.room, link, errors);
    }
    if (errors.length) throw new Error(`console errors:\n${errors.join('\n')}`);
    log(`done: ${SHOTS}/review-analysis-*.png`);
  } catch (e) {
    console.error(e);
    process.exitCode = 1;
  } finally {
    stopEngine();
    await browser.close();
  }
})();
