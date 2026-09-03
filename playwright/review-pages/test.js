/**
 * Captures the library, game start pages, and a lobby at desktop and phone
 * widths for visual review. Run with the server up:
 *   node playwright/review-pages/test.js
 */
const playwright = require('playwright');
const BASE = 'http://localhost:4000';
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
    await page.goto(`${BASE}/`); await page.waitForSelector('[data-phx-main].phx-connected'); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-01-library.png` });
    await page.goto(`${BASE}/backgammon`); await page.waitForSelector('[data-phx-main].phx-connected'); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-02-backgammon-start.png` });
    await page.fill('input[name="player_name"]', 'Alice'); await page.click('#create-game');
    await page.waitForSelector('#format-single'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-03-backgammon-lobby.png`, fullPage: true });
    await page.goto(`${BASE}/backgammon`); await page.waitForSelector('[data-phx-main].phx-connected'); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-04-backgammon-start.png` });
    await ctx.close();
  }
  await browser.close();
})();
