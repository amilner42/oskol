/**
 * The Elm landing pages, end to end.
 *
 * 1. Screenshots of the home page and the friend dialog, phone and
 *    desktop; the removed games' old links redirect home
 * 2. The home page is the title, the demo board, the one sentence and ROLL
 *    DICE, with Puzzles, JOIN and Sign in in the bar; nothing scrolls
 *    sideways at either width, and the sentence's menus and the friend
 *    dialog work without leaving the page
 * 3. A full create -> play click-through: Alice creates a backgammon game and
 *    lands in the waiting room, Bob opens the invite link and types a name,
 *    and both end up at the board
 * 4. Coming home with a game open: the bar's "1 live game" pill (the list
 *    never opens by itself) opens the list of games to resume, which
 *    closes in one tap and takes Alice back to the table
 *
 * Run with the server up:  node playwright/test-spa-landing/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, barItem, openHome, pickWord, createGame, joinByLink } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/test-spa-landing';
const PHONE = { width: 390, height: 844 };
const DESKTOP = { width: 1280, height: 900 };
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

/**
 * A phone's bar (720px and under) is the bird, the themes and ☰, and nothing else shows;
 * ☰ carries a dot when this browser has live games, and its menu has every
 * way in. `live` is how many live games the menu should list (0 for none).
 * Leaves the menu shut.
 */
async function checkPhoneBar(page, tag, live) {
  const shown = await page.evaluate(() =>
    [...document.querySelectorAll('.lh-bar a, .lh-bar button, .lh-bar input')]
      .filter((e) => e.offsetParent !== null && getComputedStyle(e).visibility !== 'hidden')
      .map((e) => e.id || e.className)
  );
  if (shown.length !== 3 || shown[0] !== 'lh-mark' || shown[1] !== 'bg-theme-button' || shown[2] !== 'nav-more')
    throw new Error(`${tag}: the bar shows ${JSON.stringify(shown)}, not the bird, the themes and ☰`);
  const dot = await page.isVisible('#nav-more .lh-burger-dot');
  if (dot !== live > 0) throw new Error(`${tag}: ☰'s live games dot is ${dot ? 'on' : 'off'} with ${live} live games`);
  await page.click('#nav-more');
  await page.waitForSelector('#nav-menu');
  const items = await page.$$eval('#nav-menu button', (bs) => bs.map((b) => b.id));
  const want = [...(live ? ['nav-live'] : []), 'nav-puzzles', 'nav-analysis', 'nav-join-game', 'nav-signin'];
  if (JSON.stringify(items) !== JSON.stringify(want))
    throw new Error(`${tag}: ☰'s menu has ${JSON.stringify(items)}, not ${JSON.stringify(want)}`);
  if (live) {
    const text = (await page.innerText('#nav-live')).replace(/\s+/g, ' ').trim();
    const words = `${live} live game${live === 1 ? '' : 's'}`;
    if (text !== words) throw new Error(`${tag}: ☰'s live games item reads "${text}"`);
  }
  await page.keyboard.press('Escape');
  await page.waitForSelector('#nav-menu', { state: 'detached' });
}

const watch = (page, who, errors) => {
  page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
  });
};

async function shots(browser, viewport, tag, errors) {
  const context = await browser.newContext({ viewport });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  try {
    const page = await context.newPage();
    watch(page, tag, errors);

    if ((await openHome(page)) !== 'guest') throw new Error('a fresh browser was not shown the guest home');
    await page.waitForSelector('.lh-board .db-checker');
    // The board's checkers animate in; let them settle on a frame.
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${SHOTS}/${tag}-01-home.png`, fullPage: true });

    // The home page: OSKOL over the demo board, the one sentence and ROLL
    // DICE under it, and the bar with the ways in.
    const title = (await page.textContent('.lh-title')).trim();
    if (title !== 'OSKOL') throw new Error(`the title reads "${title}"`);
    const checkers = await page.locator('.lh-board .db-checker').count();
    if (checkers !== 30) throw new Error(`the home board shows ${checkers} checkers, not 30`);
    const said = (await page.textContent('#sentence')).replace(/\s+/g, ' ').trim();
    if (!/^Play .+ against .+ with .+$/.test(said)) throw new Error(`the sentence reads "${said}"`);
    // The bar is the bird, the themes and ☰ at every width, and a fresh
    // browser's ☰ has no live games in it (checkPhoneBar checks the dot).
    await checkPhoneBar(page, tag, 0);
    if (!(await page.isVisible('#roll-dice'))) throw new Error('there is no PLAY NOW');
    // PUZZLES is a way in, not a promise: it opens the practice home
    // without a page load, and the home is still a tap away.
    await barItem(page, 'puzzles');
    await page.waitForSelector('#puzzles-hub');
    if (new URL(page.url()).pathname !== '/puzzles') throw new Error(`PUZZLES landed on ${page.url()}`);
    await page.goBack();
    await page.waitForSelector('#roll-dice');
    // Nothing scrolls sideways at either width.
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    if (overflow > 0) throw new Error(`the home page scrolls sideways by ${overflow}px`);

    // Against a friend the sentence grows a clock and the button asks for a
    // link; pressing it asks the guest's name over the page, no page load.
    await pickWord(page, 'who', 'pick-who-friend');
    await page.waitForSelector('#pick-clock');
    const label = (await page.textContent('#roll-dice')).replace(/\s+/g, ' ').trim();
    if (!label.startsWith('Get a link')) throw new Error(`against a friend the button reads "${label}"`);
    await pickWord(page, 'game', 'pick-game-match3');
    await pickWord(page, 'clock', 'pick-clock-bg3');
    await page.click('#roll-dice');
    await page.waitForSelector('#friend-modal #friend-name');
    if (new URL(page.url()).pathname !== '/') throw new Error(`the friend dialog navigated to ${page.url()}`);
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${SHOTS}/${tag}-02-create.png`, fullPage: true });
    await page.click('#close-friend');
    await page.waitForSelector('#friend-modal', { state: 'detached' });
    // Against Sage the clock is words, not a menu: the bot plays without one.
    await pickWord(page, 'who', 'pick-who-bot');
    await page.waitForSelector('#sage-clock');
    if (await page.locator('#pick-clock').count()) throw new Error('against Sage there is still a clock menu');

    // A game's own page is the same home (it is the one game).
    await page.goto(`${BASE}/backgammon`);
    await page.waitForSelector('#roll-dice');

    // The games that were removed: their old links land home.
    for (const old of ['/poker', '/go?game=123456', '/chess/123456?t=secret']) {
      await page.goto(`${BASE}${old}`);
      await page.waitForSelector('#roll-dice');
      if (new URL(page.url()).pathname !== '/') throw new Error(`${old} landed on ${page.url()}`);
    }
    log(`${tag} screenshots done`);
  } finally {
    await context.close();
  }
}

async function clickThrough(browser, errors) {
  const context = await browser.newContext({ viewport: DESKTOP });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  // A seat is held by the browser's guest cookie, so the two players are
  // two browsers: a second page in Alice's context is Alice, and the room
  // refuses her a second seat.
  const bobContext = await browser.newContext({ viewport: DESKTOP });
  await bobContext.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  try {
    const alice = await context.newPage();
    watch(alice, 'alice', errors);

    // Validation is inline and does not leave the page: GET A LINK with no
    // name is refused in the friend dialog.
    await openHome(alice);
    await pickWord(alice, 'who', 'pick-who-friend');
    await alice.click('#roll-dice');
    await alice.waitForSelector('#friend-modal #friend-name');
    if ((await alice.inputValue('#friend-name')) !== '') throw new Error('a fresh browser has a name prefilled');
    await alice.click('#friend-go');
    await alice.waitForSelector('#friend-modal #form-error');
    if (new URL(alice.url()).pathname !== '/') throw new Error(`the empty name navigated to ${alice.url()}`);
    log('empty name rejected inline');
    await alice.click('#close-friend');

    const game = await createGame(alice, { name: 'Alice', mode: 'match3', clock: 'bg3' });

    // The waiting room: her seat, the invite link and the code.
    await alice.waitForSelector('#game-code');
    const gameId = (await alice.textContent('#game-code')).trim();
    if (gameId !== game.gameId) throw new Error(`the code reads ${gameId}, the URL says ${game.gameId}`);
    const seatPath = new URL(alice.url()).pathname;
    if (seatPath !== `/backgammon/${game.gameId}`) throw new Error(`creator landed at ${seatPath}`);
    if (new URL(alice.url()).searchParams.get('t')) throw new Error('a seat URL must carry no token');
    const summary = await alice.textContent('#setup-summary');
    if (!/Match to 3/.test(summary) || !/3 min/.test(summary))
      throw new Error(`waiting room summary reads "${summary}"`);
    await alice.screenshot({ path: `${SHOTS}/desktop-04-waiting.png`, fullPage: true });
    log(`game ${gameId} created; waiting room shown`);

    const bob = await bobContext.newPage();
    watch(bob, 'bob', errors);
    const seat = await joinByLink(bob, game.inviteUrl, 'Bob');
    if (!/Match to 3/.test(seat.summary)) throw new Error(`invite summary reads "${seat.summary}"`);

    await alice.waitForSelector('.checker', { timeout: 20000 });
    await bob.waitForSelector('.checker', { timeout: 20000 });
    await alice.waitForTimeout(500);
    await alice.screenshot({ path: `${SHOTS}/desktop-06-table.png` });
    if (new URL(bob.url()).pathname !== `/backgammon/${gameId}`)
      throw new Error(`joiner landed at ${bob.url()}`);
    log('both players at the board: CREATE -> PLAY OK');

    // Alice goes home. Her browser holds a seat in an unfinished game: the
    // bar says so, and the list stays shut until she asks for it.
    await openHome(alice);
    await alice.waitForSelector('#nav-more .lh-burger-dot');
    await alice.waitForTimeout(400);
    if (await alice.locator('#resume-modal').count()) throw new Error('the list of live games opened by itself');
    // ☰ wears a dot, and its menu says how many.
    await checkPhoneBar(alice, 'desktop', 1);
    await barItem(alice, 'live');
    await alice.waitForSelector('#resume-modal');
    const row = alice.locator(`#resume-${gameId}`);
    const rowText = (await row.textContent()).replace(/\s+/g, ' ').trim();
    // With a clock, the row shows the two times (as of the room's last
    // step, the running one counting down) rather than the preset's name.
    if (!/Bob/.test(rowText) || !/Match to 3/.test(rowText) || !/\d+:\d\d \/ \d+:\d\d/.test(rowText))
      throw new Error(`the resume row reads "${rowText}"`);
    if (!/(Your|Their) move/.test(rowText)) throw new Error(`the resume row says nothing about whose move: "${rowText}"`);
    await alice.screenshot({ path: `${SHOTS}/desktop-07-resume.png`, fullPage: true });

    // A tap on the backdrop closes it; ☰ opens it again.
    await alice.mouse.click(8, 8);
    await alice.waitForSelector('#resume-modal', { state: 'detached' });
    await barItem(alice, 'live');
    await alice.waitForSelector('#resume-modal');
    await alice.click(`#resume-${gameId}`);
    await alice.waitForSelector('.checker', { timeout: 20000 });
    if (new URL(alice.url()).pathname !== `/backgammon/${gameId}`)
      throw new Error(`resuming landed at ${alice.url()}`);
    log('home -> live games -> back at the table: RESUME OK');

    // The same list on a phone, upright and sideways: it must fit without
    // the page scrolling sideways, and ☰ must stay in the bar. Same
    // context, so the same guest holds the seat.
    for (const [tag, viewport] of [
      ['phone-390', { width: 390, height: 844 }],
      ['phone-320', { width: 320, height: 568 }],
      ['landscape-844', { width: 844, height: 390 }],
    ]) {
      const small = await context.newPage();
      watch(small, tag, errors);
      await small.setViewportSize(viewport);
      await openHome(small);
      await small.waitForSelector('#nav-more .lh-burger-dot');
      const barWide = await small.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth
      );
      if (barWide > 0) throw new Error(`${tag}: the bar makes the page ${barWide}px too wide`);
      // The bar is the bird, the themes and ☰ (the dot says there are games).
      const pill = '#nav-more';
      await checkPhoneBar(small, tag, 1);
      const plate = await small.locator(pill).boundingBox();
      const bar = await small.locator('.lh-bar').boundingBox();
      if (!plate || !bar || plate.y < bar.y || plate.y + plate.height > bar.y + bar.height + 1 ||
          plate.x < bar.x || plate.x + plate.width > bar.x + bar.width + 1)
        throw new Error(`${tag}: ${pill} is not inside the bar`);
      await small.screenshot({ path: `${SHOTS}/${tag}-08-home-with-games.png` });
      await barItem(small, 'live');
      await small.waitForSelector('#resume-modal');
      await small.waitForTimeout(300);
      await small.screenshot({ path: `${SHOTS}/${tag}-07-resume.png` });
      const wide = await small.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth
      );
      if (wide > 0) throw new Error(`${tag}: the resume list makes the page ${wide}px too wide`);
      await small.mouse.click(4, 4);
      await small.waitForSelector('#resume-modal', { state: 'detached' });
      await small.close();
    }
    log('resume list fits on a phone, upright and sideways');

    // Bob, with his game open too, but told through a fresh visitor's eyes:
    // a browser holding no seat sees no list and no pill.
    const nobody = await bobContext.browser().newContext({ viewport: DESKTOP });
    try {
      const stranger = await nobody.newPage();
      await openHome(stranger);
      await stranger.waitForTimeout(600);
      if (await stranger.locator('#resume-modal').count()) throw new Error('a stranger was offered games to resume');
      if (await stranger.locator('.lh-burger-dot').count()) throw new Error('a stranger has a live games dot');
    } finally {
      await nobody.close();
    }
  } finally {
    await context.close();
    await bobContext.close();
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
    await shots(browser, PHONE, 'phone', errors);
    await shots(browser, DESKTOP, 'desktop', errors);
    await clickThrough(browser, errors);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('SPA LANDING OK');
  } catch (e) {
    console.error('SPA LANDING FAILED:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
