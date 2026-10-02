/**
 * Screenshots of the four choices under a reveal's level line. SOONER, GOT
 * IT and KNEW IT apply on the tap; NEVER alone asks first. At rest (the
 * graded choice filled, its sentence under the row, the confirm's slot
 * empty); SOONER on its way (filled, the four waiting); SOONER applied;
 * NEVER asking ("YES, NEVER"); GOT IT tapped after a miss ("You missed
 * this one."); and NEVER confirmed ("Set aside").
 *
 * At every size it also measures `#pz-reveal` across a tap on each of the
 * four, in flight and applied, and fails if the height moves by a pixel.
 *
 * The page is the real one on a real puzzle (`test-puzzle/setup.exs`); the
 * browser is a guest, so the attempt's answer is the server's own with a
 * schedule spliced in (what an account would be sent), and the override is
 * answered in the browser. Phone, small, sideways and desktop.
 *
 *   playwright/review-verdict/run.sh
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-outcomes';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

const DAY = 86400000;
const PASSED = { level_before: 2, level_after: 3, due: Date.now() + 7 * DAY, amendable: true, self_grade: false, patched: false };
const MISSED = { level_before: 3, level_after: 0, due: Date.now() + DAY, amendable: true, self_grade: false, patched: false };
const SOONER = { level_before: 2, level_after: 0, due: Date.now() + DAY, amendable: true, self_grade: false, patched: false };
const KNOWN = { level_before: 2, level_after: 7, due: Date.now() + 365 * DAY, amendable: true, self_grade: false, patched: true };
// What each override answers: the review it named, replaced.
const OVERRIDES = { sooner: SOONER, got_it: PASSED, knew_it: KNOWN, never: SOONER };

const SHAPES = {
  pass: { verdict: 'pass', band: 'best', cost: 0.0, schedule: PASSED },
  miss: { verdict: 'fail', band: 'doubtful', cost: 0.04, schedule: MISSED },
};

function must(ok, what) {
  if (!ok) throw new Error(`FAILED: ${what}`);
  log(`ok: ${what}`);
}

function arrange() {
  if (process.env.PUZZLE_JSON) return JSON.parse(process.env.PUZZLE_JSON);
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  return JSON.parse(resultLine(out));
}

async function stageATurn(page) {
  for (let i = 0; i < 6; i++) {
    if (await page.locator('#bg-action-play').count()) return;
    const source = page.locator('.bg-point.source, .bg-bar.source');
    if (!(await source.count())) return;
    await source.first().click();
    await page.waitForTimeout(150);
  }
}

async function revealed(browser, size, puzzle, shape) {
  const context = await browser.newContext({ viewport: { width: size.width, height: size.height }, deviceScaleFactor: 1 });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  await context.route(/\/papi\/puzzles\/[^/]+\/attempts$/, async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    Object.assign(body, shape);
    await route.fulfill({ response, json: body });
  });
  const posts = [];
  // Held a moment, as a real round trip is, so the choice on its way is
  // seen (and measured) before it lands.
  const hold = { ms: 250 };
  await context.route(/\/papi\/puzzles\/[^/]+\/attempts\/[^/]+\/outcome$/, async (route) => {
    const outcome = JSON.parse(route.request().postData() || '{}').outcome;
    posts.push(outcome);
    await new Promise((r) => setTimeout(r, hold.ms));
    await route.fulfill({ status: 200, json: { ok: true, schedule: OVERRIDES[outcome] || SOONER } });
  });
  const page = await context.newPage();
  await page.goto(`${BASE}/puzzles/${puzzle}`);
  await page.waitForSelector('#pz-board .bg-stack');
  await stageATurn(page);
  await page.click('#bg-action-play');
  await page.waitForSelector('#pz-outcomes');
  await page.waitForTimeout(300);
  await page.locator('#pz-reveal').scrollIntoViewIfNeeded();
  return { context, page, posts, hold };
}

// The choice has landed: in force, and the four free again.
async function landed(page, id) {
  await page.waitForFunction((sel) => {
    const b = document.querySelector(sel);
    return b && b.getAttribute('aria-pressed') === 'true' && !b.disabled && !b.classList.contains('is-busy');
  }, `#pz-outcome-${id}`);
}

async function shot(page, size, name) {
  await page.locator('#pz-level').scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${OUT}/${name}-${size.name}.png`, fullPage: size.name !== 'landscape' });
}

(async () => {
  const setup = arrange();
  const puzzle = setup.players[0].puzzle.id;
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  try {
    for (const size of SIZES) {
      // A pass: the graded GOT IT in force, then each of the four tapped.
      {
        const { context, page, posts, hold } = await revealed(browser, size, puzzle, SHAPES.pass);
        const height = async () => (await page.locator('#pz-reveal').boundingBox()).height;
        const rest = await height();
        const same = async (what) => {
          const h = await height();
          must(h === rest, `${size.name}: ${what}, the reveal is ${h}px as it was`);
        };
        must(!(await page.locator('#pz-never-yes').isVisible()), `${size.name}: nothing asked, the confirm's slot is empty`);
        must(!(await page.locator('#pz-apply').count()), `${size.name}: there is no APPLY`);
        must((await page.textContent('#pz-outcome-why')).trim() === 'As graded. Level 2 → 3 · back in 7 days.', `${size.name}: the graded choice explained`);
        await shot(page, size, 'rest');

        // SOONER: applied on the tap, filled at once, the four waiting.
        await page.click('#pz-outcome-sooner');
        await page.waitForSelector('#pz-outcome-sooner.is-busy');
        must(await page.locator('.pz-outcome:disabled').count() === 4, `${size.name}: in flight, the four are disabled`);
        must((await page.textContent('#pz-outcome-why')).trim() === 'Back to the start: it comes back tomorrow. Level 2 → 0.', `${size.name}: SOONER explained as it goes`);
        await same('SOONER in flight');
        await shot(page, size, 'sooner-sending');
        await landed(page, 'sooner');
        must(posts.join() === 'sooner', `${size.name}: the tap posted SOONER, once`);
        must((await page.textContent('#pz-level-line')).trim() === 'Level 2 → 0 · back tomorrow', `${size.name}: the level line moved`);
        await same('SOONER applied');
        await shot(page, size, 'sooner-applied');

        // KNEW IT, then GOT IT: each replaces the one before.
        await page.click('#pz-outcome-knew-it');
        await landed(page, 'knew-it');
        await same('KNEW IT applied');
        await page.click('#pz-outcome-got-it');
        await landed(page, 'got-it');
        await same('GOT IT applied');
        must(posts.join() === 'sooner,knew_it,got_it', `${size.name}: one post a tap, in order (${posts.join()})`);
        must(await page.locator('.pz-outcome.is-on').count() === 1, `${size.name}: one choice in force`);

        // The choice in force, tapped again, sends nothing.
        await page.click('#pz-outcome-got-it');
        await page.waitForTimeout(80);
        must(posts.length === 3, `${size.name}: the choice in force, tapped again, posts nothing`);

        // NEVER asks; another tap takes the question back; YES, NEVER sends it.
        await page.click('#pz-outcome-never');
        await page.waitForSelector('#pz-never-yes:not(.is-idle)');
        must((await page.textContent('#pz-never-yes')).trim() === 'YES, NEVER', `${size.name}: NEVER asks YES, NEVER`);
        must(posts.length === 3, `${size.name}: NEVER's tap posts nothing`);
        await same('NEVER asking');
        await shot(page, size, 'never-asking');
        await page.click('#pz-outcome-got-it');
        await page.waitForTimeout(80);
        must(!(await page.locator('#pz-never-yes').isVisible()), `${size.name}: another tap takes NEVER's question back`);
        must(posts.length === 3, `${size.name}: and, GOT IT being in force, posts nothing`);
        await page.click('#pz-outcome-never');
        hold.ms = 0;
        await page.click('#pz-never-yes');
        await page.waitForFunction(() => (document.querySelector('#pz-level-line') || {}).textContent === 'Set aside: it will not come back.');
        must(posts.join() === 'sooner,knew_it,got_it,never', `${size.name}: YES, NEVER posted NEVER`);
        must(await page.locator('.pz-outcome:disabled').count() === 4, `${size.name}: set aside, the four stay, disabled`);
        await same('NEVER confirmed');
        await shot(page, size, 'never-confirmed');
        await context.close();
      }
      // A miss: SOONER in force, GOT IT barred in its column.
      {
        const { context, page, posts } = await revealed(browser, size, puzzle, SHAPES.miss);
        const rest = (await page.locator('#pz-reveal').boundingBox()).height;
        await page.click('#pz-outcome-got-it', { force: true });
        await page.waitForTimeout(60);
        must((await page.textContent('#pz-outcome-why')).trim() === 'You missed this one.', `${size.name}: GOT IT after a miss says why`);
        must(posts.length === 0, `${size.name}: and posts nothing`);
        must((await page.locator('#pz-reveal').boundingBox()).height === rest, `${size.name}: and moves nothing`);
        await shot(page, size, 'missed-got-it');
        await context.close();
      }
      log(`${size.name}: done`);
    }
  } finally {
    await browser.close();
  }
  log(`screenshots in ${OUT}`);
})().catch((e) => { console.error(e); process.exit(1); });
