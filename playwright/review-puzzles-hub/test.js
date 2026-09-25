/**
 * Screenshots of the practice home and a run, for eyeballing.
 *
 * The one-deck hub in each of its three states, over a deck shaped like
 * the one on the human's phone (111 mistakes, 50 in rotation, none
 * patched): leading with ?? and FIX ONE; ?? in good shape with ?
 * offered; everything in good shape with nothing to press. Then the
 * summary after exactly one mistake (a run that answered one and no
 * more) and a session mid-run (the tier's mark, the day's count, the
 * marks so far, why this position is here).
 * Plus the hub as a stranger and as a guest, the end screen a guest is
 * asked to sign in on, and the same account's home. All at 390x844,
 * 320x568, 844x390 and a desktop.
 *
 * The room is arranged by `test-puzzle/setup.exs` (a finished game graded
 * against a stubbed engine), the first seat trimmed to three mistakes so
 * a run is three puzzles.
 *
 *   node playwright/review-puzzles-hub/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');

const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-puzzles-hub';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const KEPT = 3;
const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

function arrange() {
  log('arranging a graded game (mix run playwright/test-puzzle/setup.exs)');
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/test-puzzle/setup.exs")'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024,
  });
  const setup = JSON.parse(resultLine(out));
  const trim = `
    import Ecto.Query
    ids =
      Oskol.Repo.all(from(s in Oskol.Puzzles.Source,
        where: s.game_id == ${JSON.stringify(setup.game_id)} and s.player_id == ${JSON.stringify(setup.players[0].id)},
        order_by: s.turn, select: s.id))
    Oskol.Repo.delete_all(from(s in Oskol.Puzzles.Source, where: s.id in ^Enum.drop(ids, ${KEPT})))
    IO.puts(Jason.encode!(%{kept: min(length(ids), ${KEPT})}))
  `;
  execFileSync('mix', ['run', '-e', trim], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return setup;
}

/**
 * One account's deck, made to look like the human's: 111 mistakes, 61
 * never started, 50 in progress, 0 patched. Replaces what is there, so
 * it runs after every other shot.
 */
function shapeDeck(email, state) {
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/review-puzzles-hub/shape.exs")'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, SHAPE_EMAIL: email, SHAPE_STATE: state },
  });
  return JSON.parse(resultLine(out));
}

async function mailFor(request, email) {
  for (let i = 0; i < 50; i++) {
    const res = await request.get(`${BASE}/dev/last-login`);
    if (res.ok()) {
      const body = await res.json();
      if (body.email === email) return body;
    }
    await sleep(200);
  }
  throw new Error(`no sign-in mail for ${email}`);
}

async function stageATurn(page) {
  for (let i = 0; i < 6; i++) {
    await page.waitForSelector('#bg-action-play, [data-move-source]', { timeout: 10000 });
    if (await page.locator('#bg-action-play').count()) return;
    await page.locator('[data-move-source]').first().click();
    await sleep(120);
  }
}

/** One puzzle of a run, answered, left on its reveal. */
async function answerOne(page) {
  await page.waitForSelector('#pz-reveal', { state: 'detached' });
  await page.waitForSelector('#pz-board .bg-stack');
  await page.waitForSelector('#pz-bands, #bg-action-play, [data-move-source]', { timeout: 10000 });
  if (await page.locator('#pz-bands').count()) {
    await page.click('#pz-band-0');
  } else {
    await stageATurn(page);
    await page.click('#bg-action-play');
  }
  await page.waitForSelector('#pz-next, #pz-done');
}

/** ANOTHER where there is one, else I'M DONE: on, wherever it leads. */
async function next(page) {
  const was = new URL(page.url()).pathname;
  await page.click((await page.locator('#pz-next').count()) ? '#pz-next' : '#pz-done');
  await page.waitForFunction(
    (w) => new URL(location.href).pathname !== w || document.querySelector('#pz-end'),
    was,
    { timeout: 10000 }
  );
}

async function runToEnd(page, left = KEPT) {
  for (let n = 1; n <= left; n++) {
    await page.waitForSelector('#pz-reveal', { state: 'detached' });
    await page.waitForSelector('#pz-board .bg-stack');
    await page.waitForSelector('#pz-bands, #bg-action-play, [data-move-source]', { timeout: 10000 });
    if (await page.locator('#pz-bands').count()) {
      await page.click('#pz-band-0');
    } else {
      await stageATurn(page);
      await page.click('#bg-action-play');
    }
    await page.waitForSelector('#pz-next, #pz-done');
    const was = new URL(page.url()).pathname;
    await page.click((await page.locator('#pz-next').count()) ? '#pz-next' : '#pz-done');
    await page.waitForFunction(
      (w) => new URL(location.href).pathname !== w || document.querySelector('#pz-end'),
      was,
      { timeout: 10000 }
    );
  }
  await page.waitForSelector('#pz-end');
}

async function shotAtEverySize(page, name, ready) {
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await page.waitForSelector(ready);
    await sleep(200);
    await page.screenshot({ path: `${OUT}/${size.name}-${name}.png` });
  }
  log(`${name} shot`);
}

(async () => {
  const setup = arrange();
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  try {
    // A stranger's home.
    const strangerContext = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await strangerContext.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const stranger = await strangerContext.newPage();
    await stranger.goto(`${BASE}/puzzles`);
    await shotAtEverySize(stranger, '01-hub-stranger', '#hub-try-one');
    await strangerContext.close();

    // A guest's home, her run, and the end of it.
    const context = await seatedContext(browser, setup.players[0].guest, { viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await context.newPage();
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '02-hub-guest', '#hub-practice');
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click('#hub-practice');
    await runToEnd(page);
    await shotAtEverySize(page, '03-end-guest', '#pz-signin-ask');

    // Sign in from the end screen; the deck fills; the home as an account.
    await page.setViewportSize({ width: 390, height: 844 });
    const email = `review-${Date.now()}@oskol.test`;
    await page.fill('#signin-email', email);
    await page.click('#signin-send');
    await page.waitForSelector('#signin-code');
    const mail = await mailFor(page.request, email);
    await page.fill('#signin-code', mail.code);
    await page.waitForSelector('#signin-win');
    await page.click('#signin-continue');
    await page.waitForSelector('#puzzles-hub');
    let deck = 0;
    for (let i = 0; i < 30 && deck === 0; i++) {
      const body = await (await page.request.get(`${BASE}/papi/practice`)).json();
      deck = (body.counts && body.counts.deck) || 0;
      if (deck === 0) await sleep(500);
    }
    if (deck === 0) execFileSync('mix', ['oskol.puzzles.sync', '--write'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    // The deck, shaped like the one on the human's phone: 111 mistakes,
    // 50 in rotation, none patched. Everything below is that deck in
    // each of the hub's three states.
    log(`shaping the deck: ${JSON.stringify(shapeDeck(email, 'lead'))}`);

    // 1. Leading with ??: the mark, what is left to fix, FIX ONE, and
    //    the other tiers as quiet rows.
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '04-hub-lead', '#hub-fix-one');

    // 2. The summary after exactly one mistake: stopping has to read as
    //    a finished thing to have done, so the shot is of a run that
    //    answered one and no more.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click('#hub-fix-one');
    await answerOne(page);
    await page.click('#pz-done');
    await page.waitForSelector('#pz-end');
    await shotAtEverySize(page, '05-end-one-mistake', '#pz-score');

    // 3. A session mid-run: the tier's mark and the day's count over the
    //    board, the marks so far, and why this position is here.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-fix-one');
    await page.click('#hub-fix-one');
    await answerOne(page);
    await next(page);
    await page.waitForSelector('#pz-progress');
    await shotAtEverySize(page, '06-session-mid-run', '#pz-progress');

    // 4. ?? in good shape, with ? offered instead.
    log(`shaping the deck: ${JSON.stringify(shapeDeck(email, 'good_shape'))}`);
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '07-hub-good-shape', '#hub-tier-next');

    // 5. Everything in good shape: one warm line, nothing to press.
    log(`shaping the deck: ${JSON.stringify(shapeDeck(email, 'all_clear'))}`);
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '08-hub-all-clear', '#hub-tier-good');

    // The same account's home: the PUZZLES section, which is the same
    // card. `review-home` has no deck to draw, so it is shot here.
    log(`shaping the deck: ${JSON.stringify(shapeDeck(email, 'lead'))}`);
    await page.goto(`${BASE}/`);
    await shotAtEverySize(page, '09-home-practice', '#home-tier');

    await context.close();
    log(`screenshots in ${OUT}`);
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
