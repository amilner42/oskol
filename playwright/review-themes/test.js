/**
 * The eight backgammon boards, shot on a phone.
 *
 * Starts a real game (Alice on a phone, Bob joining so play begins), then
 * walks the header's board picker: open the list, take a board, shoot it.
 * Finally it reloads Alice's page and asserts the board she picked came
 * back -- the pick is kept in her browser and against her guest row, and
 * neither the room nor Bob is any the wiser (Bob's board is checked to be
 * still the default).
 *
 * Run with the server up:
 *   PORT=4405 node playwright/review-themes/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const OUT = process.env.SHOTS_DIR || 'playwright/screenshots/review-themes';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const THEMES = ['walnut', 'midnight', 'forest', 'sand', 'ivory', 'cherry', 'slate', 'neon'];

async function themeClass(page) {
  return page.$eval('.bg-page', (el) =>
    [...el.classList].find((c) => c.startsWith('bg-theme-')) || 'none'
  );
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const phone = { viewport: { width: 390, height: 844 } };
  const context = await browser.newContext(phone);
  // Bob browses separately: his own guest cookie and his own localStorage,
  // so what his board does is not an artefact of sharing Alice's.
  const theirs = await browser.newContext(phone);
  const errors = [];
  context.on('weberror', (e) => errors.push(e.error().message));
  theirs.on('weberror', (e) => errors.push(e.error().message));

  try {
    const p1 = await context.newPage();
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('#create-name');
    await p1.fill('input[name="player_name"]', 'Alice');
    await p1.click('#create-game');
    await p1.waitForSelector('#game-code');
    const gameId = await p1.textContent('#game-code');

    const p2 = await theirs.newPage();
    await p2.goto(`${BASE}/backgammon?game=${gameId.trim()}`);
    await p2.waitForSelector('#join-game');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');

    await p1.waitForSelector('.bg-page', { timeout: 20000 });
    await p2.waitForSelector('.bg-page', { timeout: 20000 });
    await sleep(1500);
    log(`game ${gameId.trim()} is on`);

    for (const theme of THEMES) {
      await p1.click('#bg-theme-button');
      await p1.waitForSelector('#bg-theme-list');
      await p1.click(`[data-theme-option="${theme}"]`);
      await p1.waitForSelector(`.bg-page.bg-theme-${theme}`, { timeout: 5000 });
      await sleep(250);
      await p1.screenshot({ path: `${OUT}/phone-${theme}.png` });
      log(`shot ${theme}`);
    }

    // The list itself, open, on the last board taken.
    await p1.click('#bg-theme-button');
    await p1.waitForSelector('#bg-theme-list');
    await p1.screenshot({ path: `${OUT}/phone-picker-open.png` });
    await p1.click('#bg-theme-button');

    // The opponent's board is untouched: a theme is display only. Reloaded
    // first, so this is what the server would tell a second browser -- not
    // just a tab nobody disturbed.
    await p2.reload();
    await p2.waitForSelector('.bg-page', { timeout: 20000 });
    const bobs = await themeClass(p2);
    if (bobs !== 'bg-theme-walnut') {
      throw new Error(`the opponent's board changed too: ${bobs}`);
    }

    // And it survives a reload (localStorage now, the guest row next time).
    await p1.reload();
    await p1.waitForSelector('.bg-page', { timeout: 20000 });
    const kept = await themeClass(p1);
    if (kept !== 'bg-theme-neon') throw new Error(`the pick did not survive a reload: ${kept}`);
    log('the pick survived a reload, and the opponent never saw it');

    // The narrow phone and the sideways one: the header still fits, with
    // the list open, and nothing scrolls sideways.
    for (const [w, h, tag] of [[320, 844, 'narrow'], [844, 390, 'landscape']]) {
      await p1.setViewportSize({ width: w, height: h });
      await sleep(400);
      await p1.click('#bg-theme-button');
      await p1.waitForSelector('#bg-theme-list');
      await sleep(200);
      await p1.screenshot({ path: `${OUT}/${tag}-picker-open.png` });
      // With the list open: nothing of it (nor of the header behind it) may
      // stick out past the viewport.
      const overflow = await p1.evaluate(() => {
        const width = document.documentElement.clientWidth;
        const spill = [...document.querySelectorAll('.bg-page *')]
          .map((el) => el.getBoundingClientRect())
          .filter((r) => r.width > 0)
          .reduce((worst, r) => Math.max(worst, Math.ceil(r.right - width), Math.ceil(-r.left)), 0);
        return Math.max(spill, document.documentElement.scrollWidth - width);
      });
      await p1.click('#bg-theme-button');
      if (overflow > 0) throw new Error(`${tag}: something is ${overflow}px past the edge`);
      log(`${tag}: header and list fit inside the screen`);
    }

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log(`PASS -- screenshots in ${OUT}`);
    await browser.close();
  } catch (e) {
    console.error(`FAIL: ${e.message}`);
    if (errors.length) console.error(errors.join('\n'));
    await browser.close();
    process.exit(1);
  }
})();
