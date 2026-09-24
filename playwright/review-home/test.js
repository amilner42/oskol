/**
 * Screenshots of the signed-in home, for eyeballing. No assertions: what
 * this is for is looking at the page at the sizes it has to work at.
 *
 *   node playwright/review-home/test.js
 *
 * It runs `playwright/test-home/setup.exs`, which makes two accounts -- one
 * with two dozen graded single games and a match to seven behind it, one
 * that signed up a minute ago -- and takes:
 *
 *   01-home     a player with a history: form and streak, live games,
 *               practice, recent matches
 *   01b-match   the match to seven opened up, its nine games under it
 *   02-empty    the same page the day the account was made
 *   03-create   PLAY's dialog over it (no name asked: the account has one)
 *   04-boards   the board picker open
 *
 * at 390x844, 320x568, 844x390 and 1440x900. The PNGs are not committed.
 */
const playwright = require('playwright');
const fs = require('fs');
const { execSync } = require('child_process');
const { BASE, resultLine, seatedContext } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/review-home';
const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 568 },
  { name: 'landscape', width: 844, height: 390 },
  { name: 'desktop', width: 1440, height: 900 },
];

async function shots(page, label) {
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await page.waitForTimeout(250);
    await page.screenshot({ path: `${SHOTS}/${label}-${size.name}.png`, fullPage: true });
    console.log(`${SHOTS}/${label}-${size.name}.png`);
  }
  await page.setViewportSize({ width: 390, height: 844 });
}

async function home(browser, guestId) {
  const context = await seatedContext(browser, guestId, { viewport: { width: 390, height: 844 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const page = await context.newPage();
  await page.goto(`${BASE}/`);
  await page.waitForSelector('#home-bar');
  await page.waitForSelector('#home-form');
  return { context, page };
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const fixture = JSON.parse(
    resultLine(
      execSync(`mix run -e 'Code.eval_file("playwright/test-home/setup.exs")'`, {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'inherit'],
      })
    )
  );
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  try {
    const full = await home(browser, fixture.guest_id);
    await shots(full.page, '01-home');

    // A match opened in place: the thing this list exists to show.
    await full.page.click(`#home-room-${fixture.match_id}`);
    await full.page.waitForSelector(`#home-room-${fixture.match_id}-games`);
    await shots(full.page, '01b-match');
    await full.page.click(`#home-room-${fixture.match_id}`);

    await full.page.click('#home-play');
    await full.page.waitForSelector('#create-modal #create-as');
    await shots(full.page, '03-create');
    await full.page.click('#close-create');

    await full.page.click('#bg-theme-button');
    await full.page.waitForSelector('#bg-theme-list');
    await shots(full.page, '04-boards');
    await full.context.close();

    const empty = await home(browser, fixture.empty_guest_id);
    await shots(empty.page, '02-empty');
    await empty.context.close();
  } finally {
    await browser.close();
  }
}

main();
