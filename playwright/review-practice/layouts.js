// EXPERIMENT (local only): the hub's layouts, as the shaped account, at a
// phone and a desktop. GUEST_ID is the account's guest cookie from setup.exs.
const playwright = require('playwright');
const { BASE, seatedContext } = require('../lib/flows');

(async () => {
  const out = process.env.SHOTS_DIR || 'playwright/screenshots/review-layouts';
  require('fs').mkdirSync(out, { recursive: true });
  const browser = await playwright.chromium.launch({ executablePath: process.env.PW_CHROMIUM || undefined });
  for (const [name, viewport] of [['phone', { width: 390, height: 844 }], ['desktop', { width: 1440, height: 900 }]]) {
    const context = await seatedContext(browser, process.env.GUEST_ID, { viewport });
    const page = await context.newPage();
    await page.goto(`${BASE}/puzzles`);
    await page.waitForSelector('#hub-cards');
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${out}/cards-${name}.png`, fullPage: true });
    await page.click('#hub-cc-very_bad-grid');
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/cards-grid-${name}.png`, fullPage: true });
    await context.close();
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
