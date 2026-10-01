/**
 * Screenshots of the practice home (/puzzles), five decks, for every
 * visitor and every state the deck in front can be in, at 390x844,
 * 320x568, 844x390 and 1440x900 -- with the page held still: every shot
 * also measures what must not move and fails if it did.
 *
 *   01 account, the very bad moves with work today: FIX ONE, the ring part
 *      full, every colour of the grid, the cost lines and what patching won
 *      back
 *   02 the same with the replies tapped into the front (a 15x21 grid)
 *   03 account, today's set done: KEEP GOING
 *   04 account, everything started and nothing due: PRACTICE ANYWAY
 *   05 a fresh account: nothing of theirs yet, the openings in front, START
 *   06 a guest with games: their worst tier, PRACTICE, nothing kept
 *   07 a stranger: what this is, TRY ONE, the five as rows
 *   08 a stranger with the openings tapped in front: TRY
 *   09 (no shot) OPEN on the hub's card sits inside the eyebrow's line
 *
 * And each deck's own page (/practice/<slug>):
 *
 *   10-14 the shaped account on all five: very bad, bad, dubious, the
 *         openings, the replies (FIX ONE / PRACTICE)
 *   15    the very bad moves with today's set done: KEEP GOING
 *   16    every very bad move started, none due: PRACTICE ANYWAY
 *   17-18 a fresh account: the openings (START), a tier with nothing yet
 *   19    a guest on their worst tier: their count, all paper, PRACTICE
 *   20-21 a stranger: the openings (TRY, the sign-in), a tier (one line)
 *
 * A deck page's loading state holds 320px; once drawn, its card and the
 * whole page are the same box as they land and once the animations are
 * done, and while a press says STARTING...
 *
 * What is measured, and must be equal:
 *   - #puzzles-hub's height before tapping a row and after tapping back;
 *   - the card's box while its press is on the way (STARTING...) and after;
 *   - the card's box as the page lands and once its animations are done
 *     (the squares and the ring animate opacity, transform and the arc
 *     only);
 *   - nothing scrolls sideways at any size.
 *
 * `setup.exs` arranges everyone (six graded games, three browsers, the two
 * sets on a stub engine) and `shape.exs` puts the account in each state.
 * PRACTICE_SETUP (the JSON line setup.exs printed) skips the arranging.
 *
 *   playwright/review-practice/run.sh       (serves its own port and database)
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');

const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-practice';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];
const ONLY = process.env.ONLY ? process.env.ONLY.split(',') : null;

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
  if (!condition) throw new Error(`moved: ${message}`);
  log(`still: ${message}`);
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

/** Load /puzzles and hold the card to its first box until the animations
 * are over. */
async function land(page, what) {
  await page.goto(`${BASE}/puzzles`);
  await page.waitForSelector('#puzzles-hub .dk-rows');
  const first = await box(page, '#hub-card');
  const hubFirst = await box(page, '#puzzles-hub');
  await sleep(1800);
  const settled = await box(page, '#hub-card');
  const hubSettled = await box(page, '#puzzles-hub');
  must(same(first, settled), `${what}: the card as it lands and once it has settled ${JSON.stringify(settled)}`);
  must(same(hubFirst, hubSettled), `${what}: the page as it lands and once it has settled (${hubSettled.h}px)`);
}

/** Tap a row in, and the one that was in front back: the page is the
 * height it was. */
async function tapAndBack(page, what) {
  const was = await page.getAttribute('#hub-card', 'data-deck');
  const before = await box(page, '#puzzles-hub');
  const row = page.locator('button.dk-row').first();
  const other = await row.getAttribute('data-deck');
  await row.click();
  await page.waitForSelector(`#hub-card[data-deck="${other}"]`);
  await page.click(`#hub-row-${was}`);
  await page.waitForSelector(`#hub-card[data-deck="${was}"]`);
  await sleep(100);
  const after = await box(page, '#puzzles-hub');
  must(same(before, after), `${what}: #puzzles-hub is ${after.h}px before ${other} came in front and after ${was} went back`);
}

/** Press the card's button with its answer held back: the card is the
 * same box while it says STARTING... as before. */
async function pressHeld(page, what) {
  if (!(await page.locator('#hub-go:not([disabled])').count())) return;
  const before = await box(page, '#hub-card');
  const slot = await box(page, '#hub-card .dk-action');
  let release;
  const held = new Promise((r) => (release = r));
  await page.route(/\/papi\/(practice|decks)/, async (route) => {
    if (route.request().url().includes('/papi/practice/decks')) return route.continue();
    await held;
    await route.abort().catch(() => {});
  });
  await page.click('#hub-go');
  await page.waitForFunction(() => /STARTING/.test(document.querySelector('#hub-go').textContent));
  const during = await box(page, '#hub-card');
  const slotDuring = await box(page, '#hub-card .dk-action');
  release();
  // Aborted before the route goes: a press let through would start the
  // run (KEEP GOING writes), and every later shot would be of another day.
  await sleep(150);
  await page.unroute(/\/papi\/(practice|decks)/);
  must(same(before, during), `${what}: the card while its press is on the way`);
  must(same(slot, slotDuring), `${what}: the button's slot while it says STARTING`);
}

async function shoot(context, name, prepare, checks = {}) {
  if (ONLY && !ONLY.some((o) => name.startsWith(o))) return;
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await land(page, `${name} ${size.name}`);
    if (prepare) await prepare(page);
    await sleep(1400);
    await noSideways(page, `${name} ${size.name}`);
    if (checks.tap && size.name === 'phone') await tapAndBack(page, `${name} ${size.name}`);
    await page.mouse.move(0, 0);
    await page.screenshot({ path: `${OUT}/${name}-${size.name}.png`, fullPage: true });
    if (checks.press && size.name === 'phone') {
      await pressHeld(page, `${name} ${size.name}`);
      await page.goto('about:blank');
    }
  }
  if (errors.length) throw new Error(`${name}: ${errors.join('; ')}`);
  await page.close();
  log(`${name} shot`);
}

// ---------- a deck's own page: /practice/<slug> ----------

/** Load a deck's page and hold it still: the loading box is the 320px it
 * promises, the card is the same box as it lands and once its animations
 * are over, and the page is the same height. */
async function landPage(page, slug, what) {
  // The answer held back a moment, so the loading state is measurable.
  let release;
  const held = new Promise((r) => (release = r));
  await page.route(new RegExp(`/papi/practice/decks/${slug}$`), async (route) => {
    await held;
    await route.continue();
  });
  await page.goto(`${BASE}/practice/${slug}`);
  await page.waitForSelector('#practice-loading');
  const loading = await box(page, '#practice-loading');
  must(loading.h === 320, `${what}: the loading state holds 320px (${loading.h})`);
  release();
  await page.waitForSelector('#practice-card, #practice-empty');
  await page.unroute(new RegExp(`/papi/practice/decks/${slug}$`));
  const sel = (await page.locator('#practice-card').count()) ? '#practice-card' : '#practice-empty';
  const first = await box(page, sel);
  const pageFirst = await box(page, '#practice-page');
  await sleep(1800);
  const settled = await box(page, sel);
  const pageSettled = await box(page, '#practice-page');
  must(same(first, settled), `${what}: ${sel} as it lands and once it has settled ${JSON.stringify(settled)}`);
  must(same(pageFirst, pageSettled), `${what}: the page as it lands and once it has settled (${pageSettled.h}px)`);
}

/** Press the page's one button with its answer held back: nothing on the
 * page moves while it says STARTING... */
async function pressHeldPage(page, what) {
  if (!(await page.locator('#practice-go:not([disabled])').count())) return;
  const before = await box(page, '#practice-page');
  const card = await box(page, '#practice-card');
  let release;
  const held = new Promise((r) => (release = r));
  await page.route(/\/papi\/(practice|decks)/, async (route) => {
    if (route.request().url().includes('/papi/practice/decks')) return route.continue();
    await held;
    await route.abort().catch(() => {});
  });
  await page.click('#practice-go');
  await page.waitForFunction(() => /STARTING/.test(document.querySelector('#practice-go').textContent));
  const during = await box(page, '#practice-page');
  const cardDuring = await box(page, '#practice-card');
  release();
  await sleep(150);
  await page.unroute(/\/papi\/(practice|decks)/);
  must(same(card, cardDuring), `${what}: the card while its press is on the way`);
  must(same(before, during), `${what}: the page while its press is on the way (${during.h}px)`);
}

async function shootPage(context, name, slug, checks = {}) {
  if (ONLY && !ONLY.some((o) => name.startsWith(o))) return;
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await landPage(page, slug, `${name} ${size.name}`);
    await noSideways(page, `${name} ${size.name}`);
    await page.mouse.move(0, 0);
    await page.screenshot({ path: `${OUT}/${name}-${size.name}.png`, fullPage: true });
    if (checks.press && size.name === 'phone') {
      await pressHeldPage(page, `${name} ${size.name}`);
      await page.goto('about:blank');
    }
  }
  if (errors.length) throw new Error(`${name}: ${errors.join('; ')}`);
  await page.close();
  log(`${name} shot`);
}

/** The hub's card with OPEN on it is the height it would be without: the
 * link sits on the eyebrow's line. */
async function openHolds(context, what) {
  if (ONLY && !ONLY.some((o) => '09-hub-open'.startsWith(o))) return;
  const page = await context.newPage();
  await page.setViewportSize({ width: 320, height: 568 });
  await page.goto(`${BASE}/puzzles`);
  await page.waitForSelector('#hub-open');
  const name = await box(page, '#hub-card .dk-name-row');
  const open = await box(page, '#hub-open');
  must(open.h <= name.h && open.y >= name.y && open.y + open.h <= name.y + name.h, `${what}: OPEN sits inside the eyebrow's line (${open.h} in ${name.h})`);
  await page.close();
}

(async () => {
  const setup =process.env.PRACTICE_SETUP ? JSON.parse(process.env.PRACTICE_SETUP) : mix('playwright/review-practice/setup.exs');
  log(`arranged: ${JSON.stringify(setup)}`);
  const shape = (state) => log(`shaped: ${JSON.stringify(mix('playwright/review-practice/shape.exs', { SHAPE_EMAIL: setup.email, SHAPE_STATE: state }))}`);

  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  const context = async (guest) => {
    const c = guest ? await seatedContext(browser, guest, { deviceScaleFactor: 2 }) : await browser.newContext({ deviceScaleFactor: 2 });
    await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    return c;
  };
  try {
    const account = await context(setup.guest);
    shape('ladder');
    await shoot(account, '01-account-fix-one', null, { tap: true, press: true });
    await shoot(account, '02-account-replies-in-front', async (page) => {
      await page.click('#hub-row-opening_replies');
      await page.waitForSelector('#hub-card[data-deck="opening_replies"]');
    });
    await openHolds(account, '09-hub-open');
    // Each deck's own page, for the same account in the same state.
    await shootPage(account, '10-page-very-bad', 'very-bad', { press: true });
    await shootPage(account, '11-page-bad', 'bad');
    await shootPage(account, '12-page-dubious', 'dubious');
    await shootPage(account, '13-page-openings', 'openings', { press: true });
    await shootPage(account, '14-page-opening-replies', 'opening-replies');
    shape('keep_going');
    await shoot(account, '03-account-keep-going', null, { press: true });
    await shootPage(account, '15-page-very-bad-keep-going', 'very-bad', { press: true });
    shape('scheduled');
    await shoot(account, '04-account-practice-anyway', null, { press: true });
    await shootPage(account, '16-page-very-bad-practice-anyway', 'very-bad', { press: true });
    await account.close();

    const fresh = await context(setup.fresh);
    await shoot(fresh, '05-fresh-account', null, { tap: true, press: true });
    await shootPage(fresh, '17-page-openings-fresh', 'openings', { press: true });
    await shootPage(fresh, '18-page-very-bad-fresh', 'very-bad');
    await fresh.close();

    const guest = await context(setup.bob);
    await shoot(guest, '06-guest', null, { tap: true, press: true });
    // The guest's own worst tier, whichever it is: the hub's card says.
    const guestSlug = await (async () => {
      const p = await guest.newPage();
      await p.goto(`${BASE}/puzzles`);
      await p.waitForSelector('#hub-card');
      const id = await p.getAttribute('#hub-card', 'data-deck');
      await p.close();
      return id === 'doubtful' ? 'dubious' : id.replace(/_/g, '-');
    })();
    await shootPage(guest, '19-page-tier-guest', guestSlug, { press: true });
    await guest.close();

    const stranger = await context(null);
    await shoot(stranger, '07-stranger');
    await shoot(stranger, '08-stranger-openings', async (page) => {
      await page.click('#hub-row-openings');
      await page.waitForSelector('#hub-card[data-deck="openings"]');
    });
    await shootPage(stranger, '20-page-openings-stranger', 'openings', { press: true });
    await shootPage(stranger, '21-page-very-bad-stranger', 'very-bad');
    await stranger.close();
    log(`screenshots in ${OUT}`);
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
