/**
 * Captures the home board, CREATE GAME's dialog and a lobby at desktop and
 * phone widths for visual review. Run with the server up:
 *   node playwright/review-pages/test.js
 */
const playwright = require('playwright');
const { BASE, openCreateDialog, createGame } = require('../lib/flows');
const OUT = process.argv[2] || 'playwright/screenshots/review-pages';
const fs = require('fs'); fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  for (const [name, vp] of [['desktop', { width: 1280, height: 900 }], ['phone', { width: 390, height: 844 }]]) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
  // External fonts are blocked in sandboxes and would stall the load event.
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await ctx.newPage();
    await page.goto(`${BASE}/`); await page.waitForSelector('#home-menu #start-game'); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-01-home.png` });
    await openCreateDialog(page); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-02-create-dialog.png`, fullPage: true });
    // The lobby: create a backgammon game, which lands on /backgammon/<id>: a
    // seat is the guest who took it, so the URL carries no secret.
    await createGame(page, { name: 'Alice', mode: 'match5' }); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-03-backgammon-lobby.png`, fullPage: true });
    // The theme picker, open on the home board.
    await page.goto(`${BASE}/`); await page.waitForSelector('#bg-theme-button');
    await page.click('#bg-theme-button'); await page.waitForSelector('#bg-theme-list'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-04-theme-picker.png` });
    await ctx.close();
  }
  await browser.close();
})();
