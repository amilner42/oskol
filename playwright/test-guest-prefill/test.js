/**
 * Guest identity smoke: the site silently remembers a visitor's name.
 *
 * 1. Create a game against a friend as "Alice" (a brand-new guest's friend
 *    dialog starts empty)
 * 2. GET A LINK again in the same browser context: the friend dialog's name
 *    is prefilled "Alice" (guest cookie -> saved name), and ROLL DICE
 *    against Sage seats the browser as "Alice" with nothing to type
 * 3. A fresh context (a different visitor) gets an empty field, and plays
 *    Sage as "Guest"
 *
 * Run with the server up:  node playwright/test-guest-prefill/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { openHome, pickWord, createGame } = require('../lib/flows');

// The guest home's GET A LINK: the friend dialog, filled in by nobody.
async function openFriendDialog(page) {
  await openHome(page);
  await pickWord(page, 'who', 'pick-who-friend');
  await page.click('#roll-dice');
  await page.waitForSelector('#friend-modal #friend-name');
}

// The name the table shows on this browser's own seat.
async function myName(page) {
  const bar = page.locator('.player-bar.is-me .font-bold').first();
  await bar.waitFor();
  return (await bar.textContent()).trim();
}

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
    await openFriendDialog(page);
    if ((await page.inputValue('#friend-name')) !== '')
      throw new Error('a brand-new guest must start with an empty name field');
    await page.click('#close-friend');
    await createGame(page, { name: 'Alice' });
    log('game created as Alice');

    // Same browser, GET A LINK again: the site remembers.
    await openFriendDialog(page);
    const prefilled = await page.inputValue('#friend-name');
    if (prefilled !== 'Alice') throw new Error(`expected prefill "Alice", saw "${prefilled}"`);
    await page.screenshot({ path: `${SHOTS}/01-prefilled.png` });
    await page.click('#close-friend');
    log('the friend dialog prefills Alice');

    // Against Sage there is nothing to type: the remembered name is used.
    await createGame(page, { opponent: 'bot' });
    const seated = await myName(page);
    if (seated !== 'Alice') throw new Error(`a Sage game was played as "${seated}", not the remembered "Alice"`);
    log('a Sage game is played as Alice');

    // A different visitor (fresh context, no cookie) sees an empty field,
    // and plays Sage as "Guest".
    const fresh = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    await fresh.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    try {
      const other = await fresh.newPage();
      watch(other, 'fresh');
      await openFriendDialog(other);
      const empty = await other.inputValue('#friend-name');
      if (empty !== '') throw new Error(`a fresh visitor saw a prefilled name: "${empty}"`);
      await other.screenshot({ path: `${SHOTS}/02-fresh-empty.png` });
      await other.click('#close-friend');
      await createGame(other, { opponent: 'bot' });
      const nameless = await myName(other);
      if (nameless !== 'Guest') throw new Error(`a fresh visitor played Sage as "${nameless}", not "Guest"`);
    } finally {
      await fresh.close();
    }
    log('fresh context is empty and plays Sage as Guest; PREFILL OK');
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
