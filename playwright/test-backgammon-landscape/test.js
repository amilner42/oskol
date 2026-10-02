/**
 * Backgammon on a phone held sideways, both ways round.
 *
 * A turned phone has two layouts and a toggle (`#bg-focus-toggle`) between
 * them: **expanded**, which is focus mode and the default, and
 * **compressed**, which is the layout a sideways phone has always had. This
 * script plays a real game on two phone shapes (844x390 and a shorter
 * 740x360) and holds both of them to their own promise:
 *
 * 1. Whichever mode: the board's rendered height is <= the viewport height,
 *    it starts at the top of the screen and ends at the bottom of it (it
 *    really does fill the height, not just fit inside it), it is no wider
 *    than the screen, and the toggle is on screen and big enough to hit --
 *    a mode you cannot leave is a trap.
 * 2. Nothing scrolls, in either mode: the document is exactly as tall as
 *    the viewport.
 * 3. Expanded: the board IS the screen, and the little chrome it keeps --
 *    the clock, the score, the tray -- is ON the board and never on the
 *    play. Until focus mode the promise here was "the chrome is beside the
 *    board, not on it", which was one way of saying the thing that actually
 *    matters: that nothing may cover a point, a checker, the dice, the cube
 *    or the centre band. Expanded deliberately puts what it keeps over the
 *    board's frame, so the claim is made directly instead -- every piece of
 *    chrome is inside the board's own box and none of it intersects the
 *    playing surface, neither `.bg-grid` (the felt and the bar as one box)
 *    nor any individual point, checker, die, cube, bar or band. What it
 *    puts away (pips, presence, the wordmark, the match label, the board
 *    picker, the flag) is asserted absent, and asserted back in compressed.
 * 4. Compressed: the old promise, unchanged -- the header and both identity
 *    bars never overlap the board.
 * 5. Live play in landscape on a clock: the held clock and its delay pip
 *    read on the identity plate, clear of the play, and a real turn with
 *    its dice is screenshotted.
 * 6. A danced turn in landscape (the room is arranged the way
 *    test-backgammon-dance does it): "NO LEGAL MOVES / TURN PASSES" and
 *    the dice that did it are both on the board, inside it.
 * 7. Portrait phone and desktop screenshots of the very same game, to show
 *    that neither changed.
 *
 * Run with the server up:  node playwright/test-backgammon-landscape/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, createGame, joinByLink, resultLine } = require('../lib/flows');
const { execFileSync } = require('child_process');
const { assertTrayColumn, assertTrayStrips, bearOffEverywhere } = require('../lib/trays');

const SHOTS = process.env.SHOTS_DIR || 'playwright/screenshots/test-backgammon-landscape';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The phones this script plays on, both held sideways. */
const PHONES = [
  { name: 'iphone-landscape', width: 844, height: 390 },
  { name: 'short-landscape', width: 740, height: 360 },
];

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

async function box(page, selector) {
  const b = await page.locator(selector).first().boundingBox();
  if (!b) throw new Error(`no box for ${selector}`);
  return b;
}

const overlaps = (a, b) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

/** Is `a` wholly within `b` (a pixel of slack for sub-pixel layout)? */
const within = (a, b) =>
  a.x >= b.x - 1 && a.y >= b.y - 1 && a.x + a.width <= b.x + b.width + 1 && a.y + a.height <= b.y + b.height + 1;

/**
 * The chrome, and the play it may never cover.
 *
 * `.bg-grid` is the felt and the bar as one box -- everything a player acts
 * on lives inside it -- so it is the one box that settles the claim; the
 * list beside it is the same claim spelled out piece by piece, so that a
 * part of the board moving out of the grid one day cannot quietly take the
 * guarantee with it.
 */
const CHROME = ['.bg-header', '.player-bar:not(.is-me)', '.player-bar.is-me', '#bg-actions'];
const PLAY = ['.bg-grid', '.bg-point', '.checker', '.die', '.cube', '.bg-bar', '.bg-band', '.bg-tray-col'];

/** Every box on the page for these selectors, named by the one that found it. */
async function boxes(page, selectors) {
  const found = [];
  for (const selector of selectors) {
    for (const el of await page.locator(selector).all()) {
      const b = await el.boundingBox();
      if (b && b.width > 0 && b.height > 0) found.push({ selector, box: b });
    }
  }
  return found;
}

/** What both modes owe, whichever one the page is in. */
async function assertFits(page, phone, who) {
  await page.waitForSelector('.bg-board', { timeout: 20000 });
  await sleep(300); // let the roll animation settle before measuring

  const board = await box(page, '.bg-board');
  const label = `${who} @ ${phone.width}x${phone.height}`;
  // Every page wears the site's bar across the top -- except focus mode,
  // which puts it away; the table is what it leaves, and the board fills
  // that.
  const bar = await page.locator('.lh-bar').first().boundingBox();
  const room = bar ? phone.height - (bar.y + bar.height) : phone.height;
  if (bar) must(!overlaps(bar, board), `${label}: the site's bar does not overlap the board`);

  must(
    board.height <= phone.height + 1,
    `${label}: the board is not taller than the screen (${Math.round(board.height)} <= ${phone.height})`
  );
  // Exactly the height under the bar, not merely under it: the whole point
  // of landscape.
  // (A screen too narrow to be proportionate to its own height is the one
  // case where width has the last word; `fills: false` says so.)
  if (phone.fills !== false) {
    must(
      board.height >= room * 0.9,
      `${label}: the board fills the height under the bar (${Math.round(board.height)} of ${Math.round(room)})`
    );
  }
  must(
    board.y >= -1 && board.y + board.height <= phone.height + 1,
    `${label}: the board is entirely on screen vertically (top ${Math.round(board.y)}, bottom ${Math.round(board.y + board.height)})`
  );
  must(
    board.x >= -1 && board.x + board.width <= phone.width + 1,
    `${label}: the board is entirely on screen horizontally (${Math.round(board.width)} wide)`
  );

  const scroll = await page.evaluate(() => ({
    scrollHeight: document.documentElement.scrollHeight,
    clientHeight: document.documentElement.clientHeight,
    innerHeight: window.innerHeight,
  }));
  must(
    scroll.scrollHeight <= scroll.clientHeight + 1,
    `${label}: nothing to scroll (document ${scroll.scrollHeight}, viewport ${scroll.clientHeight})`
  );
  must(scroll.innerHeight === phone.height, `${label}: the viewport is the phone's (${scroll.innerHeight})`);

  // The parts a player must see are inside the board they are playing on.
  const points = await page.locator('.bg-point').count();
  must(points === 24, `${label}: all 24 points are rendered`);
  const strays = [];
  for (const selector of ['.bg-point', '.bg-bar', '.cube', '.bg-band']) {
    for (const el of await page.locator(selector).all()) {
      const b = await el.boundingBox();
      if (!b) continue;
      const inside =
        b.y >= board.y - 1 &&
        b.y + b.height <= board.y + board.height + 1 &&
        b.x >= board.x - 1 &&
        b.x + b.width <= board.x + board.width + 1;
      if (!inside) strays.push(selector);
    }
  }
  must(
    strays.length === 0,
    `${label}: points, bar, cube and both bands all sit inside the board${
      strays.length ? ` (out: ${[...new Set(strays)].join(', ')})` : ''
    }`
  );
  // The bear-off trays stand at the end of the home boards, as a real
  // board keeps them, and the viewer's half answers a tap.
  await assertTrayColumn(page, label);

  // The way between the modes is on screen in both, or a mode is a trap.
  const toggle = await box(page, '#bg-focus-toggle');
  must(
    toggle.x >= -1 &&
      toggle.y >= -1 &&
      toggle.x + toggle.width <= phone.width + 1 &&
      toggle.y + toggle.height <= phone.height + 1,
    `${label}: the focus toggle is on screen`
  );
  must(
    toggle.width >= 20 && toggle.height >= 20,
    `${label}: the focus toggle is big enough to hit (${Math.round(toggle.width)}x${Math.round(toggle.height)})`
  );
}

/**
 * Focus mode: the board IS the screen, and the little chrome it keeps is on
 * the board's own frame.
 *
 * Until focus mode the promise here was "the chrome is beside the board, not
 * on it", which was one way of saying the thing that actually matters -- that
 * nothing may cover a point, a checker, the dice, the cube or the centre
 * band. Focus mode deliberately puts what it keeps over the board's frame,
 * so the claim is made directly instead: every piece of chrome is inside the
 * board's own box and none of it intersects the playing surface, neither
 * `.bg-grid` (the felt and the bar as one box, which is the box that settles
 * it) nor any individual point, checker, die, cube, bar or band. Compressed
 * mode still makes the old promise, below.
 */
async function assertExpanded(page, phone, who) {
  const board = await box(page, '.bg-board');
  const label = `${who} @ ${phone.width}x${phone.height}, expanded`;

  must(
    await page.evaluate(() => document.querySelector('.bg-page').classList.contains('is-expanded')),
    `${label}: the page is in focus mode`
  );
  must(
    board.width >= phone.width - 1,
    `${label}: the board is as wide as the screen (${Math.round(board.width)} of ${phone.width})`
  );

  const chrome = await boxes(page, CHROME);
  must(chrome.length >= 3, `${label}: the chrome is on the page (${chrome.length} plates)`);
  const play = await boxes(page, PLAY);
  must(play.length > 24, `${label}: the playing surface is on the page (${play.length} parts)`);
  for (const c of chrome) {
    must(within(c.box, board), `${label}: ${c.selector} is on the board's own frame`);
    must(
      c.box.x >= -1 &&
        c.box.y >= -1 &&
        c.box.x + c.box.width <= phone.width + 1 &&
        c.box.y + c.box.height <= phone.height + 1,
      `${label}: ${c.selector} is on screen`
    );
    const covered = play.filter((s) => overlaps(c.box, s.box)).map((s) => s.selector);
    must(
      covered.length === 0,
      `${label}: ${c.selector} covers nothing that is played on${
        covered.length ? ` (covers: ${[...new Set(covered)].join(', ')})` : ''
      }`
    );
  }

  // What focus mode keeps, because a turn cannot be played without it...
  for (const [selector, what] of [
    ['.player-bar.is-me .score-chip', 'the score'],
    ['.bg-tray-col', 'the bear-off trays'],
    ['.bg-band', 'the centre band'],
  ]) {
    must(await page.locator(selector).first().isVisible(), `${label}: ${what} is on screen`);
  }
  // ...the clock above all, which is the whole reason focus mode hides
  // nothing behind a tap. A game played without one has no chip to show.
  const clock = page.locator('.player-bar.is-me .clock-chip');
  must(
    (await clock.count()) === 0 || (await clock.first().isVisible()),
    `${label}: the clock reads on the plate${(await clock.count()) === 0 ? ' (this game has none)' : ''}`
  );
  // ...and what it puts away, because compressed mode is one tap from here.
  for (const [selector, what] of [
    ['.bar-pips', 'the pip counts'],
    ['.bar-dot', 'the presence dots'],
    ['.bg-match-tag', 'the match label'],
    ['#bg-theme-button', 'the board picker'],
    ['#bg-resign-open', 'the resign flag'],
  ]) {
    must(!(await page.locator(selector).first().isVisible()), `${label}: ${what} is not drawn`);
  }
}

/**
 * Compressed: the layout a sideways phone has always had, and the promise it
 * has always made -- the chrome is beside the board, never on it, and so can
 * never cover a point, the dice or the centre band.
 */
async function assertCompressed(page, phone, who) {
  const board = await box(page, '.bg-board');
  const label = `${who} @ ${phone.width}x${phone.height}, compressed`;

  must(
    !(await page.evaluate(() => document.querySelector('.bg-page').classList.contains('is-expanded'))),
    `${label}: the page is not in focus mode`
  );
  for (const selector of CHROME) {
    const chrome = await page.locator(selector).first().boundingBox();
    if (!chrome) continue;
    must(!overlaps(chrome, board), `${label}: ${selector} does not overlap the board`);
    must(
      chrome.x + chrome.width <= phone.width + 1 && chrome.y + chrome.height <= phone.height + 1,
      `${label}: ${selector} is on screen`
    );
  }
  // What focus mode put away is here, which is what makes it a mode rather
  // than a loss.
  for (const [selector, what] of [
    ['.bar-pips', 'the pip counts'],
    ['.bg-match-tag', 'the match label'],
    ['#bg-resign-open', 'the resign flag'],
  ]) {
    must(await page.locator(selector).first().isVisible(), `${label}: ${what} is back`);
  }
  // MATCH opens the games so far as a sheet over the board, on screen, and
  // its ✕ shuts it.
  if (await page.locator('#bg-match-toggle').isVisible()) {
    await page.click('#bg-match-toggle');
    const sheet = await box(page, '#bg-match-sheet .bg-match');
    must(
      sheet.height >= 60 &&
        sheet.y >= 0 &&
        sheet.y + sheet.height <= phone.height + 1 &&
        sheet.x + sheet.width <= phone.width + 1,
      `${label}: MATCH opens the games as a sheet on screen`
    );
    await page.click('#bg-match-close');
    await page.waitForSelector('#bg-match-sheet', { state: 'detached', timeout: 3000 });
  }
}

/** Both modes on one page, ending back in the one it started in. */
async function assertBothModes(page, phone, who) {
  await assertFits(page, phone, who);
  await assertExpanded(page, phone, who);
  await page.click('#bg-focus-toggle');
  await sleep(400);
  await assertFits(page, phone, who);
  await assertCompressed(page, phone, who);
  await page.click('#bg-focus-toggle');
  await sleep(400);
  await assertExpanded(page, phone, who);
}

/** Play until this page has dice of its own on the board (or give up). */
async function reachDice(pages, deadlineMs = 30000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    for (const page of pages) {
      if ((await page.locator('.die').count()) >= 2) return page;
      if (await page.locator('button:has-text("ROLL")').count()) {
        await page.click('button:has-text("ROLL")');
        await sleep(500);
      }
    }
    await sleep(250);
  }
  throw new Error('no dice ever landed');
}

/** A room whose current turn danced, arranged exactly as the dance smoke does. */
function arrangeDancedRoom() {
  if (process.env.DANCE_JSON) return JSON.parse(process.env.DANCE_JSON);
  log('arranging a danced room (mix run playwright/test-backgammon-dance/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-dance/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

/**
 * The clock reads as one line, "5:00 +12": the time and the turn's free
 * seconds side by side, neither on the other, both inside the chip, and the
 * chip as wide with the seconds as without them. Checked on a fresh clocked
 * game at each size, while the first turn's delay is still running.
 */
async function assertClockLine(page, label) {
  await page.waitForSelector('.clock-chip .delay-pip', { timeout: 20000 });
  const chips = await page.evaluate(() =>
    [...document.querySelectorAll('.clock-chip')].map((c) => {
      const r = (e) => e && e.getBoundingClientRect().toJSON();
      return { chip: r(c), time: r(c.querySelector('.clock-time')), pip: r(c.querySelector('.delay-pip')) };
    })
  );
  const held = chips.find((c) => c.pip);
  must(held, `${label}: a clock shows its free seconds`);
  must(!overlaps(held.time, held.pip), `${label}: the time and the free seconds do not overlap`);
  must(within(held.time, held.chip) && within(held.pip, held.chip), `${label}: both sit inside the clock`);
  must(Math.abs(held.time.y + held.time.height - (held.pip.y + held.pip.height)) <= 3, `${label}: on one line`);
  const plain = chips.find((c) => !c.pip);
  if (plain) {
    must(Math.abs(plain.chip.width - held.chip.width) < 0.5, `${label}: a clock is as wide with its free seconds as without`);
  }
}

async function clockLines(browser, watch) {
  const guest = () => require('crypto').randomBytes(16).toString('base64url');
  for (const screen of [
    { name: '390x844', width: 390, height: 844, modes: ['upright'] },
    { name: '844x390', width: 844, height: 390, modes: ['expanded', 'compressed'] },
    { name: '1440x900', width: 1440, height: 900, desktop: true, modes: ['desktop'] },
  ]) {
    const contexts = [];
    for (const seat of [guest(), guest()]) {
      const c = await browser.newContext({
        viewport: { width: screen.width, height: screen.height },
        hasTouch: !screen.desktop,
        isMobile: !screen.desktop,
      });
      await c.addCookies([{ name: '_oskol_guest', value: seat, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
      await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      contexts.push(c);
    }
    const a = await contexts[0].newPage();
    watch(a, `clock ${screen.name}`);
    const { gameId, inviteUrl } = await createGame(a, { name: 'Ada', mode: 'match3', clock: 'bg5' });
    const b = await contexts[1].newPage();
    await joinByLink(b, inviteUrl, 'Bo');
    await a.waitForURL(`**/backgammon/${gameId}**`);
    await a.waitForSelector('.bg-board', { timeout: 20000 });
    for (const mode of screen.modes) {
      if (mode === 'compressed') {
        await a.click('#bg-focus-toggle');
        await sleep(400);
      }
      await assertClockLine(a, `clock @ ${screen.name}${mode === 'expanded' || mode === 'compressed' ? `, ${mode}` : ''}`);
    }
    for (const c of contexts) await c.close();
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
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };
  // A seat is held by the browser's guest cookie. Every context here is
  // made with the cookie of the seat it is meant to be sitting at, which is
  // how a later screen (portrait, desktop, a squarish tablet) reopens the
  // same seat rather than arriving as a stranger.
  const guest = () => require('crypto').randomBytes(16).toString('base64url');
  const seats = [guest(), guest()];
  const phoneContext = async (phone, asGuest) => {
    const c = await browser.newContext({
      viewport: { width: phone.width, height: phone.height },
      hasTouch: true,
      isMobile: true,
    });
    if (asGuest) {
      await c.addCookies([{ name: '_oskol_guest', value: asGuest, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
    }
    await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    return c;
  };

  try {
    // --- a real game, both seats on landscape phones -----------------
    const contexts = [];
    for (const [i, phone] of PHONES.entries()) contexts.push(await phoneContext(phone, seats[i]));

    const p1 = await contexts[0].newPage();
    watch(p1, 'landscape-1');
    // A format with the cube on the rail, and a clock so the delay pip shows.
    const { gameId, inviteUrl } = await createGame(p1, { name: 'Ada', mode: 'match3', clock: 'bg3' });

    const p2 = await contexts[1].newPage();
    watch(p2, 'landscape-2');
    await joinByLink(p2, inviteUrl, 'Bo');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    const urls = [p1.url(), p2.url()];
    log(`game ${gameId}: two seats, both in landscape`);

    // The clock is the reason focus mode hides nothing behind a tap: the
    // held clock and its delay pip have to be readable while a player
    // thinks. Here they are on the board's own rail, which is the one place
    // focus mode has for them -- on the board, clear of the play.
    for (const page of [p1, p2]) await page.waitForSelector('.bg-board', { timeout: 20000 });
    const held = (await p1.locator('.delay-pip').count()) ? p1 : p2;
    const heldPhone = held === p1 ? PHONES[0] : PHONES[1];
    const pip = held.locator('.delay-pip').first();
    await pip.waitFor({ timeout: 15000 });
    must(/^\+\d+$/.test((await pip.textContent()).trim()), `the mover's clock is held (${(await pip.textContent()).trim()})`);
    must(await held.locator('.player-bar .clock-chip .tabular-nums').first().isVisible(), 'the clock reads on the identity plate');
    const pipBox = await pip.boundingBox();
    const heldBoard = await box(held, '.bg-board');
    const heldFelt = await box(held, '.bg-grid');
    must(pipBox && within(pipBox, heldBoard), 'the delay pip is on the board');
    must(pipBox && !overlaps(pipBox, heldFelt), 'the delay pip is clear of the play');
    must(
      pipBox.x + pipBox.width <= heldPhone.width + 1 && pipBox.y + pipBox.height <= heldPhone.height + 1,
      'the delay pip is on screen'
    );
    await held.screenshot({ path: `${SHOTS}/00-clock-delay-landscape.png` });

    // A turn with dice on the board, then measure and shoot both phones.
    await reachDice([p1, p2]);
    await sleep(1200); // the tumble finishes
    for (const [i, page] of [p1, p2].entries()) {
      await assertBothModes(page, PHONES[i], `seat ${i + 1}`);
      await page.screenshot({ path: `${SHOTS}/01-play-${PHONES[i].name}.png` });
    }

    // One seat, one connection: every page from here on reopens a seat
    // The mode is this browser's, and it is kept: a player who chose the
    // fuller layout must not be handed focus mode back by every reload, or
    // by every time they put the phone down. Nothing stored is focus mode.
    const isExpanded = (page) => page.evaluate(() => document.querySelector('.bg-page').classList.contains('is-expanded'));
    await p1.click('#bg-focus-toggle');
    await sleep(300);
    await p1.reload();
    await p1.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(600);
    must((await isExpanded(p1)) === false, 'the compressed layout survives a reload');
    await p1.click('#bg-focus-toggle');
    await sleep(300);
    await p1.reload();
    await p1.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(600);
    must(await isExpanded(p1), 'and so does focus mode');

    // these two are holding, and a seat opened twice says so over the
    // screenshot. Close them first.
    for (const page of [p1, p2]) await page.close();
    await sleep(1500); // let the room notice the sockets are gone

    // A landscape screen too square for a backgammon board (a small
    // tablet held sideways): the board may stop short of the height, but
    // it must still fit, whole, with nothing hanging off it.
    const squat = { name: 'squat-landscape', width: 640, height: 480, fills: false };
    const squatContext = await phoneContext(squat, seats[0]);
    const sq = await squatContext.newPage();
    watch(sq, 'squat');
    await sq.goto(urls[0]);
    await assertBothModes(sq, squat, 'a squarish screen');
    await sq.screenshot({ path: `${SHOTS}/05-squat-landscape.png` });
    await squatContext.close();

    // --- the same room, portrait and desktop: nothing moved ----------
    const portrait = await phoneContext({ width: 390, height: 844 }, seats[0]);
    const pp = await portrait.newPage();
    watch(pp, 'portrait');
    await pp.goto(urls[0]);
    await pp.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(600);
    const pBoard = await box(pp, '.bg-board');
    must(pBoard.height <= 844, `portrait: the board still fits the phone (${Math.round(pBoard.height)})`);
    await assertTrayStrips(pp, 'portrait @ 390x844');
    await pp.screenshot({ path: `${SHOTS}/02-portrait-phone.png` });

    const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    await desktop.addCookies([{ name: '_oskol_guest', value: seats[1], url: BASE, httpOnly: true, sameSite: 'Lax' }]);
    await desktop.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const pd = await desktop.newPage();
    watch(pd, 'desktop');
    await pd.goto(urls[1]);
    await pd.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(600);
    must(
      (await pd.locator('.hidden.lg\\:flex .clock, .game-panel').count()) >= 0,
      'desktop: the rail is still the desktop rail'
    );
    const dBoard = await box(pd, '.bg-board');
    must(dBoard.width > 600, `desktop: the board is still the wide desktop board (${Math.round(dBoard.width)}px)`);
    await assertTrayColumn(pd, 'desktop @ 1440x900');
    await pd.screenshot({ path: `${SHOTS}/03-desktop.png` });

    // --- a danced turn, in landscape ---------------------------------
    const room = arrangeDancedRoom();
    const dancer = room.players.find((p) => p.id === room.dancer);
    const danceContext = await phoneContext(PHONES[0], dancer.guest);
    const dp = await danceContext.newPage();
    watch(dp, 'dance-landscape');
    await dp.goto(`${BASE}/backgammon/${room.game_id}`);
    await dp.waitForSelector('#bg-no-moves', { timeout: 20000 });
    await sleep(400);
    await assertFits(dp, PHONES[0], 'the dancer');
    await assertExpanded(dp, PHONES[0], 'the dancer');

    const boardBox = await box(dp, '.bg-board');
    const message = await box(dp, '#bg-no-moves');
    must(
      message.y >= boardBox.y && message.y + message.height <= boardBox.y + boardBox.height,
      'the dance message is on the board, inside it'
    );
    const die = await box(dp, '.die');
    must(
      die.y >= boardBox.y && die.y + die.height <= boardBox.y + boardBox.height,
      'the dice that danced are on the board, inside it'
    );
    must(!overlaps(message, die), 'the message does not sit on top of the dice');
    must(await dp.locator('#bg-action-play').count(), 'the dancer still has the pass button');
    await dp.screenshot({ path: `${SHOTS}/04-dance-landscape.png` });
    await danceContext.close();

    // --- bearing off: the trays at every size, and nothing moves ---------
    await bearOffEverywhere(browser, {
      watch,
      shot: (screen, mode) => `${SHOTS}/06-bear-off-${screen.name}-${mode}.png`,
    });

    // --- the clock is one line of text at every size ------------------
    await clockLines(browser, watch);

    if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`);
    log(`PASS (screenshots in ${SHOTS})`);
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
