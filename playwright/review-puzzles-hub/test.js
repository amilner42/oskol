/**
 * Screenshots of the practice home and the end of a run, for eyeballing:
 * the home as a stranger, as a guest with mistakes and as an account
 * (done for today), and the end screen for a guest (the sign-in ask) and
 * for an account (KEEP GOING), at 390x844, 320x568, 844x390 and a
 * desktop.
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

async function runToEnd(page) {
  for (let n = 1; n <= KEPT; n++) {
    await page.waitForSelector('#pz-reveal', { state: 'detached' });
    await page.waitForSelector('#pz-board .bg-stack');
    await stageATurn(page);
    await page.click('#bg-action-play');
    await page.waitForSelector('#pz-next');
    const was = new URL(page.url()).pathname;
    await page.click('#pz-next');
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
    await shotAtEverySize(page, '02-hub-guest', '#hub-practise');
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click('#hub-practise');
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
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '04-hub-account', '#hub-practise');
    await page.setViewportSize({ width: 390, height: 844 });
    await page.click('#hub-practise');
    await runToEnd(page);
    await shotAtEverySize(page, '05-end-account', '#pz-done');
    await page.goto(`${BASE}/puzzles`);
    await shotAtEverySize(page, '06-hub-account-done', '#hub-keep-going');
    await context.close();
    log(`screenshots in ${OUT}`);
  } finally {
    await browser.close();
  }
})().catch((e) => { console.error(e); process.exit(1); });
