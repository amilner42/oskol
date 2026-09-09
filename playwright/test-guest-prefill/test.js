/**
 * Guest identity smoke: the site silently remembers a visitor's name.
 *
 * 1. Create a backgammon game as "Alice"
 * 2. Navigate back to the create page in the same browser context:
 *    the name field is prefilled "Alice" (guest cookie -> saved name)
 * 3. A fresh context (a different visitor) gets an empty field
 *
 * Run with the server up:  node playwright/test-guest-prefill/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const SHOTS = 'playwright/screenshots/test-guest-prefill';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

async function run(browser, errors) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const page = await context.newPage();
    watch(page, 'guest');
    await page.goto(`${BASE}/backgammon`);
    await page.waitForSelector('[data-phx-main].phx-connected');
    if ((await page.inputValue('input[name="player_name"]')) !== '')
      throw new Error('a brand-new guest must start with an empty name field');
    await page.fill('input[name="player_name"]', 'Alice');
    await page.click('#create-game');
    await page.waitForSelector('#share-link');
    log('game created as Alice');

    // Same browser, back to the create page: the site remembers.
    await page.goto(`${BASE}/backgammon`);
    await page.waitForSelector('[data-phx-main].phx-connected');
    const prefilled = await page.inputValue('input[name="player_name"]');
    if (prefilled !== 'Alice') throw new Error(`expected prefill "Alice", saw "${prefilled}"`);
    await page.screenshot({ path: `${SHOTS}/01-prefilled.png` });
    log('create page prefills Alice');

    // A different visitor (fresh context, no cookie) sees an empty field.
    const fresh = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    await fresh.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    try {
      const other = await fresh.newPage();
      watch(other, 'fresh');
      await other.goto(`${BASE}/backgammon`);
      await other.waitForSelector('[data-phx-main].phx-connected');
      const empty = await other.inputValue('input[name="player_name"]');
      if (empty !== '') throw new Error(`a fresh visitor saw a prefilled name: "${empty}"`);
      await other.screenshot({ path: `${SHOTS}/02-fresh-empty.png` });
    } finally {
      await fresh.close();
    }
    log('fresh context is empty; PREFILL OK');
  } catch (e) {
    await Promise.all(
      context.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${i}.png` }).catch(() => {}))
    );
    throw e;
  } finally {
    await context.close();
  }
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  try {
    await run(browser, errors);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
  } catch (e) {
    console.error('PREFILL SMOKE FAILED:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
