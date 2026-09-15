/**
 * Backgammon on a phone held sideways: the board fits the screen exactly.
 *
 * Landscape is meant to be the nicest way to play a wide rectangular board,
 * so this script holds the layout to that promise on two phone shapes
 * (844x390 and a shorter 740x360):
 *
 * 1. The board's rendered height is <= the viewport height, it starts at
 *    the top of the screen and ends at the bottom of it (it really does
 *    fill the height, not just fit inside it), and it is no wider than the
 *    screen either.
 * 2. Nothing scrolls: the document is exactly as tall as the viewport.
 * 3. The chrome is beside the board, not on it: the header and both
 *    identity bars (names, pips, score, clock) never overlap the board,
 *    and so can never cover a point, the dice or the centre band.
 * 4. Live play in landscape on a clock: the held clock and its delay pip
 *    read in the identity bar beside the board, and a real turn with its
 *    dice is screenshotted.
 * 5. A danced turn in landscape (the room is arranged the way
 *    test-backgammon-dance does it): "NO LEGAL MOVES / TURN PASSES" and
 *    the dice that did it are both on the board, inside it.
 * 6. Portrait phone and desktop screenshots of the very same game, to show
 *    that neither changed.
 *
 * Run with the server up:  node playwright/test-backgammon-landscape/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
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

/** Every claim the ticket makes, on one page at one size. */
async function assertFits(page, phone, who) {
  await page.waitForSelector('.bg-board', { timeout: 20000 });
  await sleep(300); // let the roll animation settle before measuring

  const board = await box(page, '.bg-board');
  const label = `${who} @ ${phone.width}x${phone.height}`;

  must(
    board.height <= phone.height + 1,
    `${label}: the board is not taller than the screen (${Math.round(board.height)} <= ${phone.height})`
  );
  // Exactly the height, not merely under it: the whole point of landscape.
  // (A screen too narrow to be proportionate to its own height is the one
  // case where width has the last word; `fills: false` says so.)
  if (phone.fills !== false) {
    must(
      board.height >= phone.height * 0.9,
      `${label}: the board fills the height (${Math.round(board.height)} of ${phone.height})`
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

  // The chrome sits beside the board, never over it.
  for (const selector of ['.bg-header', '.player-bar:not(.is-me)', '.player-bar.is-me']) {
    const chrome = await page.locator(selector).first().boundingBox();
    if (!chrome) continue;
    must(!overlaps(chrome, board), `${label}: ${selector} does not overlap the board`);
    must(
      chrome.x + chrome.width <= phone.width + 1 && chrome.y + chrome.height <= phone.height + 1,
      `${label}: ${selector} is on screen`
    );
  }

  // The parts a player must see are inside the board they are playing on.
  const points = await page.locator('.bg-point').count();
  must(points === 24, `${label}: all 24 points are rendered`);
  const strays = [];
  for (const selector of ['.bg-point', '.bg-bar', '.cube', '.bg-band']) {
    const els = await page.locator(selector).all();
    for (const el of els) {
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
  // The bear-off trays live in the identity bars, one each, inside them.
  for (const who of ['.player-bar:not(.is-me)', '.player-bar.is-me']) {
    const bar = await box(page, who);
    const tray = await box(page, `${who} .bg-tray`);
    must(
      tray.x >= bar.x - 1 && tray.x + tray.width <= bar.x + bar.width + 1 && tray.y >= bar.y - 1 && tray.y + tray.height <= bar.y + bar.height + 1,
      `${label}: the tray sits inside ${who}`
    );
  }
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
  return JSON.parse(out.trim().split('\n').pop());
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
  const phoneContext = async (phone) => {
    const c = await browser.newContext({
      viewport: { width: phone.width, height: phone.height },
      hasTouch: true,
      isMobile: true,
    });
    await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    return c;
  };

  try {
    // --- a real game, both seats on landscape phones -----------------
    const contexts = [];
    for (const phone of PHONES) contexts.push(await phoneContext(phone));

    const p1 = await contexts[0].newPage();
    watch(p1, 'landscape-1');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('#create-name');
    await p1.fill('input[name="player_name"]', 'Ada');
    await p1.click('#format-match3'); // a format with the cube on the rail
    await p1.click('#clock-blitz'); // and a clock, so the delay pip shows up
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).pathname.split('/')[2];

    const p2 = await contexts[1].newPage();
    watch(p2, 'landscape-2');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('#join-game');
    await p2.fill('input[name="player_name"]', 'Bo');
    await p2.click('#join-game');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    const urls = [p1.url(), p2.url()];
    log(`game ${gameId}: two seats, both in landscape`);

    // The clock lives in the identity bars here (the desktop rail is not
    // on a phone): the held clock and its delay pip have to be readable,
    // beside the board rather than over it.
    for (const page of [p1, p2]) await page.waitForSelector('.bg-board', { timeout: 20000 });
    const held = (await p1.locator('.delay-pip').count()) ? p1 : p2;
    const heldPhone = held === p1 ? PHONES[0] : PHONES[1];
    const pip = held.locator('.delay-pip').first();
    await pip.waitFor({ timeout: 15000 });
    must(/^\+\d+$/.test((await pip.textContent()).trim()), `the mover's clock is held (${(await pip.textContent()).trim()})`);
    must(await held.locator('.player-bar .clock-chip .tabular-nums').first().isVisible(), 'the clock reads in the identity bar');
    const pipBox = await pip.boundingBox();
    const heldBoard = await box(held, '.bg-board');
    must(pipBox && !overlaps(pipBox, heldBoard), 'the delay pip is beside the board, not on it');
    must(
      pipBox.x + pipBox.width <= heldPhone.width + 1 && pipBox.y + pipBox.height <= heldPhone.height + 1,
      'the delay pip is on screen'
    );
    await held.screenshot({ path: `${SHOTS}/00-clock-delay-landscape.png` });

    // A turn with dice on the board, then measure and shoot both phones.
    await reachDice([p1, p2]);
    await sleep(1200); // the tumble finishes
    for (const [i, page] of [p1, p2].entries()) {
      await assertFits(page, PHONES[i], `seat ${i + 1}`);
      await page.screenshot({ path: `${SHOTS}/01-play-${PHONES[i].name}.png` });
    }

    // One seat, one connection: every page from here on reopens a seat
    // these two are holding, and a seat opened twice says so over the
    // screenshot. Close them first.
    for (const page of [p1, p2]) await page.close();
    await sleep(1500); // let the room notice the sockets are gone

    // A landscape screen too square for a backgammon board (a small
    // tablet held sideways): the board may stop short of the height, but
    // it must still fit, whole, with nothing hanging off it.
    const squat = { name: 'squat-landscape', width: 640, height: 480, fills: false };
    const squatContext = await phoneContext(squat);
    const sq = await squatContext.newPage();
    watch(sq, 'squat');
    await sq.goto(urls[0]);
    await assertFits(sq, squat, 'a squarish screen');
    await sq.screenshot({ path: `${SHOTS}/05-squat-landscape.png` });
    await squatContext.close();

    // --- the same room, portrait and desktop: nothing moved ----------
    const portrait = await phoneContext({ width: 390, height: 844 });
    const pp = await portrait.newPage();
    watch(pp, 'portrait');
    await pp.goto(urls[0]);
    await pp.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(600);
    const pBoard = await box(pp, '.bg-board');
    must(pBoard.height <= 844, `portrait: the board still fits the phone (${Math.round(pBoard.height)})`);
    await pp.screenshot({ path: `${SHOTS}/02-portrait-phone.png` });

    const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 } });
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
    await pd.screenshot({ path: `${SHOTS}/03-desktop.png` });

    // --- a danced turn, in landscape ---------------------------------
    const room = arrangeDancedRoom();
    const danceContext = await phoneContext(PHONES[0]);
    const dancer = room.players.find((p) => p.id === room.dancer);
    const dp = await danceContext.newPage();
    watch(dp, 'dance-landscape');
    await dp.goto(`${BASE}/backgammon/${room.game_id}?t=${dancer.token}`);
    await dp.waitForSelector('#bg-no-moves', { timeout: 20000 });
    await sleep(400);
    await assertFits(dp, PHONES[0], 'the dancer');

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
