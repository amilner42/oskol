/**
 * Screenshots of a practice run -- the strip over the board, the moment
 * the run asks its queue again, the end card's way on, an early answer --
 * at 390x844, 320x568, 844x390 and 1440x900, with the page held still:
 * every step also measures what must not move and fails if it did.
 *
 *   01 mid-run: six tiles, the ring part full, the why-line
 *   02 the refetch: ANOTHER pressed past the run's last id, on its way
 *   03 the end card: today's set done, KEEP GOING
 *   04 after KEEP GOING: the ring's target grown by three
 *   05 I'M DONE with some of today left: KEEP GOING goes on
 *   06 PRACTICE ANYWAY: an early answer, "practice only" over the board
 *   07 the end of a run of early answers
 *   08 a run through a set: the set's name and its own ring
 *   09 past the twentieth: 24 tiles, one row, scrolled to the newest
 *
 * What is measured, and must be equal:
 *   - the strip's box (#pz-progress) and the board's top (#pz-board) at
 *     every puzzle of a run, with one tile and with twenty-four, before
 *     the answer and after it (the why-line landing in between);
 *   - the end card (#pz-end) and its way band while the shell is still
 *     asking where the deck stands and once the button is drawn;
 *   - nothing scrolls sideways at any size.
 *
 *   playwright/review-run/run.sh       (serves its own port and database)
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { stageATurn } = require('../lib/puzzles');

const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-run';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];
const PHONE = SIZES[0];

function mix(script, env = {}) {
  const out = execFileSync('mix', ['run', '-e', `Code.eval_file("${script}")`], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, ...env },
  });
  return JSON.parse(resultLine(out));
}

function must(condition, message) {
  if (!condition) throw new Error(`failed: ${message}`);
  log(`ok: ${message}`);
}

const box = (page, selector) =>
  page.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.x), y: Math.round(r.y + scrollY), w: Math.round(r.width), h: Math.round(r.height) };
  }, selector);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function noSideways(page, what) {
  const d = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, iw: innerWidth }));
  must(d.sw <= d.iw, `${what}: nothing scrolls sideways (${d.sw} <= ${d.iw})`);
}

/** The page as it stands, at every size, then back to the phone. */
async function shootAll(page, name, sizes = SIZES) {
  for (const size of sizes) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await sleep(350);
    await noSideways(page, `${name} ${size.name}`);
    await page.mouse.move(0, 0);
    await page.screenshot({ path: `${OUT}/${name}-${size.name}.png`, fullPage: size.name !== 'landscape' });
  }
  await page.setViewportSize({ width: PHONE.width, height: PHONE.height });
  await sleep(200);
  log(`${name} shot`);
}

async function answer(page) {
  await page.waitForSelector('#pz-bands, #bg-action-play, .bg-point.source, [data-move-source]', { timeout: 15000 });
  if (await page.locator('#pz-bands').count()) {
    await page.locator('#pz-bands .pz-band').first().click();
  } else {
    await stageATurn(page);
    await page.click('#bg-action-play');
  }
  await page.waitForSelector('#pz-reveal', { timeout: 15000 });
}

/** The strip and the board, as they stand. */
async function strip(page) {
  return {
    strip: await box(page, '#pz-progress'),
    board: await box(page, '#pz-board'),
    tiles: await page.locator('#pz-marks .pz-tile').count(),
    ring: await page.evaluate(() => {
      const r = document.querySelector('#pz-ring');
      return r ? `${r.dataset.done}/${r.dataset.target}` : null;
    }),
  };
}

/** One puzzle of a run on the phone: the strip and the board measured as
 * the puzzle lands and once it is answered, against the first puzzle's. */
async function onePuzzle(page, n, first) {
  await page.waitForSelector('#pz-board .bg-stack');
  await sleep(250);
  const before = await strip(page);
  must(before.tiles === n, `puzzle ${n}: a tile for each reached so far (${before.tiles})`);
  await answer(page);
  await sleep(400);
  const after = await strip(page);
  if (first) {
    must(same(first.strip, before.strip) && same(first.strip, after.strip),
      `puzzle ${n}: the strip is the box it was at the first (${JSON.stringify(after.strip)})`);
    must(same(first.board, before.board) && same(first.board, after.board),
      `puzzle ${n}: the board has not moved (${JSON.stringify(after.board)})`);
  } else {
    must(same(before.strip, after.strip), `puzzle ${n}: the answer and the why-line move nothing in the strip`);
  }
  return { before, after };
}

/** ANOTHER, and wait until it has gone somewhere (another URL, or the
 * end card on this one). */
async function another(page) {
  const was = new URL(page.url()).pathname;
  await page.click('#pz-next');
  await page.waitForFunction((from) => new URL(location.href).pathname !== from || !!document.querySelector('#pz-end'), was, { timeout: 15000 });
}

/** A route that holds its requests until released, to photograph the
 * moment a request is on its way. */
async function holder(page, pattern) {
  let release = () => {};
  let held = Promise.resolve();
  let seen = 0;
  const state = {
    hold() { held = new Promise((r) => (release = r)); },
    release() { release(); },
    get seen() { return seen; },
  };
  await page.route(pattern, async (route) => {
    seen += 1;
    await held;
    await route.continue().catch(() => {});
  });
  return state;
}

(async () => {
  const setup = process.env.RUN_SETUP_FILE ? JSON.parse(fs.readFileSync(process.env.RUN_SETUP_FILE, 'utf8')) : mix('playwright/review-practice/setup.exs');
  log(`arranged: ${JSON.stringify(setup)}`);
  const shape = (state) => log(`shaped: ${JSON.stringify(mix('playwright/review-practice/shape.exs', { SHAPE_EMAIL: setup.email, SHAPE_STATE: state }))}`);

  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const context = await seatedContext(browser, setup.guest, { deviceScaleFactor: 2, viewport: { width: PHONE.width, height: PHONE.height } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));

  try {
    // ---- the very bad moves, with work today ----
    shape('ladder');
    const refetch = await holder(page, /\/papi\/practice\?band=/);
    const standing = await holder(page, /\/papi\/practice\/decks$/);
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-go[data-action="fix-one"]');
    must((await page.getAttribute('#hub-card', 'data-deck')) === 'very_bad', 'the very bad moves are in front');
    await page.click('#hub-go');
    await page.waitForURL(/\/puzzles\/[^/]+$/);

    let first = null;
    let refetched = 0;
    let n = 0;
    for (;;) {
      n += 1;
      const { after } = await onePuzzle(page, n, first);
      if (!first) first = after;
      if (n === 6) await shootAll(page, '01-mid-run');
      // The answer that finishes today's set brings the celebration under
      // the reveal (review-celebration photographs it); its I'M DONE ends
      // the run on the end card, whose way on is measured as below.
      if (await page.locator('#pz-today-done').count()) {
        await page.waitForSelector('#pz-today-done[data-settled="true"]', { timeout: 15000 });
        standing.hold();
        await page.click('#pz-done');
        await page.waitForSelector('#pz-end');
        await sleep(200);
        const asking = { card: await box(page, '#pz-end'), band: await box(page, '#pz-way') };
        must(await page.locator('#pz-way-idle').count(), 'while the shell asks, the button is held back in its slot');
        standing.release();
        await page.waitForSelector('#pz-keep-going');
        await sleep(200);
        const offered = { card: await box(page, '#pz-end'), band: await box(page, '#pz-way') };
        must(same(asking, offered), `the end card and its way band are the same box asking and answered (${JSON.stringify(offered)})`);
        break;
      }
      // ANOTHER past the last id the run holds asks the queue again: hold
      // that request and photograph the moment.
      refetch.hold();
      const asked = refetch.seen;
      const was = new URL(page.url()).pathname;
      await page.click('#pz-next');
      await page.waitForFunction((from) => new URL(location.href).pathname !== from, was, { timeout: 1500 }).catch(() => {});
      if (new URL(page.url()).pathname !== was) {
        refetch.release();
        continue;
      }
      must(refetch.seen > asked, `after ${n} the run asks its queue again rather than ending`);
      must(await page.locator('#pz-next.is-busy').count(), 'and ANOTHER says it is on its way');
      if (!refetched) await shootAll(page, '02-refetch');
      refetched += 1;
      // The queue answers. With something new (the day's new ones come
      // after the due ones) the run goes on; with nothing, today's set is
      // done. The end card is drawn at once and its way on lands a
      // request later -- hold that one too, and measure the card both ways.
      standing.hold();
      refetch.release();
      await page.waitForFunction((from) => new URL(location.href).pathname !== from || !!document.querySelector('#pz-end'), was, { timeout: 15000 });
      if (!(await page.locator('#pz-end').count())) {
        standing.release();
        log(`the queue asked again after ${n} had more, and the run went on`);
        continue;
      }
      await sleep(200);
      const asking = { card: await box(page, '#pz-end'), band: await box(page, '#pz-way') };
      must(await page.locator('#pz-way-idle').count(), 'while the shell asks, the button is held back in its slot');
      standing.release();
      await page.waitForSelector('#pz-keep-going');
      await sleep(200);
      const offered = { card: await box(page, '#pz-end'), band: await box(page, '#pz-way') };
      must(same(asking, offered), `the end card and its way band are the same box asking and answered (${JSON.stringify(offered)})`);
      break;
    }
    log(`the run went through ${n} and ended on today's set`);
    must((await page.textContent('#pz-way-line')).includes('Keep going adds 3 more.'), 'KEEP GOING says what it adds');
    await shootAll(page, '03-end-keep-going');

    // KEEP GOING: three more, and the ring's target grows by them.
    await page.click('#pz-keep-going');
    await page.waitForSelector('#pz-board .bg-stack');
    await sleep(300);
    const grown = await strip(page);
    log(`after KEEP GOING the ring reads ${grown.ring}`);
    const [d, t] = grown.ring.split('/').map(Number);
    must(t === d + 3, `the ring's target grew by the three KEEP GOING started (${grown.ring})`);
    await answer(page);
    await sleep(400);
    await shootAll(page, '04-after-keep-going');
    await page.click('#pz-done');
    await page.waitForSelector('#pz-keep-going[data-action="continue"]');
    await sleep(200);
    await shootAll(page, '05-end-continue', [PHONE, SIZES[1]]);

    // ---- everything started, nothing due: PRACTICE ANYWAY ----
    shape('scheduled');
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-go[data-action="practice-anyway"]');
    await page.click('#hub-go');
    await page.waitForURL(/\/puzzles\/[^/]+$/);
    await page.waitForSelector('#pz-board .bg-stack');
    must((await page.textContent('#pz-progress-count')).trim() === 'Practice only', 'the strip says the run is practice only');
    await answer(page);
    await page.waitForSelector('#pz-level-line');
    const early = (await page.textContent('#pz-level-line')).trim();
    must(/^Not due until \d+ \w{3} — practice only, nothing moves\.$/.test(early), `an early answer says so: "${early}"`);
    must(!(await page.locator('#pz-outcomes').count()), 'and offers none of the four choices');
    await sleep(300);
    await shootAll(page, '06-early-answer');
    await page.click('#pz-done');
    await page.waitForSelector('#pz-practice-only');
    await page.waitForSelector('#pz-way[data-way]:not([data-way=""])');
    await sleep(200);
    await shootAll(page, '07-end-anyway', [PHONE, SIZES[1]]);

    // ---- a set ----
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-row-openings');
    await page.click('#hub-row-openings');
    await page.waitForSelector('#hub-card[data-deck="openings"]');
    await page.click('#hub-go');
    await page.waitForURL(/\/puzzles\/[^/]+$/);
    await page.waitForSelector('#pz-board .bg-stack');
    await answer(page);
    await sleep(400);
    await shootAll(page, '08-set-strip');

    // ---- past the twentieth ----
    shape('ladder');
    log(`many due: ${JSON.stringify(mix('playwright/test-puzzles-hub/many_due.exs', { SHAPE_EMAIL: setup.email, DUE_COUNT: '25' }))}`);
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-go[data-action="fix-one"]');
    await page.click('#hub-go');
    await page.waitForURL(/\/puzzles\/[^/]+$/);
    first = null;
    for (n = 1; n <= 24; n++) {
      const { after } = await onePuzzle(page, n, first);
      if (!first) first = after;
      if (n < 24) await another(page);
    }
    must(!(await page.locator('#pz-end').count()), 'the run went on past the twentieth');
    await shootAll(page, '09-past-twenty');

    if (errors.length) throw new Error(errors.join('; '));
    log(`screenshots in ${OUT}`);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
