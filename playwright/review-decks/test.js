/**
 * Screenshots of the sets on offer (the openings, the replies to them) on
 * the practice home, and a run through one: the LEARN card as an account
 * that has added the openings and not the replies, and as a guest; a
 * puzzle in a run through the openings (the strip names the set); and the
 * end card after one answer. At 390x844, 320x568, 844x390 and a desktop.
 *
 * `setup.exs` builds both sets against the stub engine and puts an
 * account part way through the openings.
 *
 *   node playwright/review-decks/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');
const { stageATurn } = require('../lib/puzzles');

const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-decks';
fs.mkdirSync(OUT, { recursive: true });
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

function arrange() {
  const out = execFileSync('mix', ['run', '-e', 'Code.eval_file("playwright/review-decks/setup.exs")'], {
    encoding: 'utf8',
    env: process.env,
  });
  process.stdout.write(out);
  return JSON.parse(resultLine(out));
}

(async () => {
  const { guest_id: guestId } = arrange();
  const browser = await playwright.chromium.launch({ executablePath: process.env.PW_CHROMIUM || undefined });

  for (const size of SIZES) {
    const viewport = { width: size.width, height: size.height };

    // An account: the openings added, the replies not.
    const account = await seatedContext(browser, guestId, { viewport });
    const page = await account.newPage();
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#decks');
    await page.screenshot({ path: `${OUT}/${size.name}-hub-account.png`, fullPage: true });
    await page.locator('#decks').screenshot({ path: `${OUT}/${size.name}-learn-account.png` });

    // Each size answers one, so by the last the openings have nothing left
    // today: that is the resting row, and a picture of its own.
    if (!(await page.locator('#deck-openings-go').count())) {
      log(`${size.name}: the openings are resting`);
      await account.close();
      continue;
    }

    // A run through the openings: the strip names the set.
    await page.click('#deck-openings-go');
    await page.waitForSelector('#pz-progress-count');
    await page.screenshot({ path: `${OUT}/${size.name}-run.png`, fullPage: true });
    const strip = await page.textContent('#pz-progress-count');
    if (!strip.startsWith('Openings')) throw new Error(`the strip says ${strip}`);

    // One answer and I'M DONE: the end card in a set's words.
    await stageATurn(page);
    await page.click('#bg-action-play');
    await page.waitForSelector('#pz-done');
    await page.screenshot({ path: `${OUT}/${size.name}-reveal.png`, fullPage: true });
    await page.click('#pz-done');
    await page.waitForSelector('#pz-end');
    await page.screenshot({ path: `${OUT}/${size.name}-end.png`, fullPage: true });
    log(`${size.name}: end card says "${(await page.textContent('#pz-score')).trim()}"`);
    await account.close();

    // A guest: TRY on each set.
    const guestContext = await browser.newContext({ viewport });
    const guest = await guestContext.newPage();
    await guest.goto(`${BASE}/puzzles`);
    await guest.waitForSelector('#decks');
    await guest.locator('#decks').screenshot({ path: `${OUT}/${size.name}-learn-guest.png` });
    await guestContext.close();
  }

  await browser.close();
  log(`screenshots in ${OUT}`);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
