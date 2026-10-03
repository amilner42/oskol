/**
 * The two ways a phone held sideways can be laid out, for eyeballing.
 *
 * Expanded (focus mode, and the default) gives the board the whole screen
 * and keeps the clock, the score and the band; compressed is the layout a
 * sideways phone has always had, the whole table beside the board.
 * `#bg-focus-toggle` moves between them, so every screen here is shot both
 * ways, in play and between games, plus the same room upright and on a
 * desktop. Off a portrait phone the bear-off trays are a column at the end
 * of the home boards (three bins of five a side); upright they stay strips
 * in the identity bars. Both are asserted on every screen here, and a
 * bear-off is played on each, holding every box on the table still.
 *
 * Run with the server up:  node playwright/review-landscape-focus/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, createGame, joinByLink } = require('../lib/flows');
const { assertTrayColumn, assertTrayStrips, bearOffEverywhere } = require('../lib/trays');

const OUT = process.argv[2] || 'playwright/screenshots/review-landscape-focus';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

/** Sideways: a tall phone, a short one, an iPhone SE, a big one, and a
 *  small tablet too square for a board. */
const SCREENS = [
  { name: 'phone-844x390', width: 844, height: 390 },
  { name: 'phone-740x360', width: 740, height: 360 },
  { name: 'phone-667x375', width: 667, height: 375 },
  { name: 'phone-932x430', width: 932, height: 430 },
  { name: 'squat-640x480', width: 640, height: 480 },
];
const UPRIGHT = { name: 'portrait-390x844', width: 390, height: 844 };
const DESKTOP = { name: 'desktop-1440x900', width: 1440, height: 900 };

const guest = () => require('crypto').randomBytes(16).toString('base64url');

const context = async (browser, vp, seat) => {
  const c = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    hasTouch: vp.width < 1024,
    isMobile: vp.width < 1024,
    deviceScaleFactor: 1,
  });
  await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  if (seat) await c.addCookies([{ name: '_oskol_guest', value: seat, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
  return c;
};

/** A room in play, on a clock, with a turn's dice on the board. */
async function playing(browser, vp, seats) {
  const ca = await context(browser, vp, seats[0]);
  const cb = await context(browser, vp, seats[1]);
  const a = await ca.newPage();
  const game = await createGame(a, { name: 'Ada', mode: 'match5', clock: 'bg_bullet' });
  const b = await cb.newPage();
  await joinByLink(b, game.inviteUrl, 'Borisov');
  await a.waitForURL(`**/backgammon/${game.gameId}**`);
  await b.waitForURL(`**/backgammon/${game.gameId}**`);
  for (const p of [a, b]) await p.waitForSelector('.bg-board', { timeout: 20000 });
  await Promise.race([
    a.waitForSelector('.bg-point.source', { timeout: 20000 }),
    b.waitForSelector('.bg-point.source', { timeout: 20000 }),
  ]);
  const mover = (await a.locator('.bg-point.source').count()) > 0 ? a : b;
  await sleep(1300); // the tumble finishes
  return { a, b, mover, game, contexts: [ca, cb] };
}

const toggle = async (page) => {
  await page.click('#bg-focus-toggle');
  await sleep(500);
};

/** Both modes, in play and between games, on one sideways screen. */
async function table(browser, vp) {
  const seats = [guest(), guest()];
  const { a, b, mover, contexts } = await playing(browser, vp, seats);

  // Expanded is what a turned phone gets with nothing stored. The trays
  // are a column at the end of the home boards in both modes.
  await assertTrayColumn(mover, `${vp.name}, expanded`);
  await mover.screenshot({ path: `${OUT}/${vp.name}-01-expanded-playing.png` });
  const source = mover.locator('.bg-point.source');
  if (await source.count()) {
    await source.first().click();
    await sleep(700);
    await mover.screenshot({ path: `${OUT}/${vp.name}-02-expanded-staged.png` });
  }

  // ...and the same board compressed.
  await toggle(mover);
  await assertTrayColumn(mover, `${vp.name}, compressed`);
  await mover.screenshot({ path: `${OUT}/${vp.name}-03-compressed-playing.png` });
  if (await mover.locator('#bg-match-toggle').count()) {
    await mover.click('#bg-match-toggle');
    await mover.waitForSelector('#bg-match-sheet');
    await sleep(400);
    await mover.screenshot({ path: `${OUT}/${vp.name}-04-compressed-match.png` });
    await mover.click('#bg-match-close');
    await mover.waitForSelector('#bg-match-sheet', { state: 'detached' });
  }
  await toggle(mover);

  // Between games: end this one with a resignation. The flag is one of the
  // things focus mode leaves to compressed mode, so this is also the check
  // that the toggle is the way to everything it puts away.
  if (!(await a.locator('#bg-resign-open').isVisible())) await toggle(a);
  await a.click('#bg-resign-open');
  await a.waitForSelector('#bg-resign-single');
  await a.click('#bg-resign-single');
  // Answering a resignation is a band button: it is there in both modes.
  await b.waitForSelector('#bg-action-accept_resign', { timeout: 15000 });
  await b.click('#bg-action-accept_resign');
  await a.waitForSelector('#bg-action-ready', { timeout: 15000 });
  await toggle(a);
  await sleep(900);
  await a.screenshot({ path: `${OUT}/${vp.name}-05-expanded-between-games.png` });
  await toggle(a);
  await a.screenshot({ path: `${OUT}/${vp.name}-06-compressed-between-games.png` });

  log(`${vp.name}: both modes`);
  for (const p of [a, b]) await p.close();
  for (const c of contexts) await c.close();
}

/** The same room upright and on a desktop: neither of them moved. */
async function unchanged(browser) {
  const seats = [guest(), guest()];
  const { a, b, mover, contexts } = await playing(browser, { name: 'x', width: 844, height: 390 }, seats);
  const url = mover === a ? a.url() : b.url();
  const seat = mover === a ? seats[0] : seats[1];
  for (const p of [a, b]) await p.close();
  for (const c of contexts) await c.close();
  await sleep(1200); // let the room notice the sockets are gone

  for (const vp of [UPRIGHT, DESKTOP]) {
    const c = await context(browser, vp, seat);
    const p = await c.newPage();
    await p.goto(url);
    await p.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(900);
    if (vp === UPRIGHT) await assertTrayStrips(p, vp.name);
    else await assertTrayColumn(p, vp.name);
    await p.screenshot({ path: `${OUT}/${vp.name}-table.png` });
    await p.close();
    await c.close();
    log(`${vp.name}: unchanged`);
  }
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  let failed = false;
  try {
    for (const vp of SCREENS) {
      try {
        await table(browser, vp);
      } catch (e) {
        failed = true;
        console.error(`${vp.name}: ${e.message}`);
      }
    }
    try {
      await unchanged(browser);
    } catch (e) {
      failed = true;
      console.error(`unchanged: ${e.message}`);
    }
    // A bear-off on every screen the trays change shape across, every box
    // on the table held still while checkers come off.
    try {
      await bearOffEverywhere(browser, { shot: (screen, mode) => `${OUT}/${screen.name}-07-bear-off-${mode}.png` });
    } catch (e) {
      failed = true;
      console.error(`bear-off: ${e.message}`);
    }
  } finally {
    await browser.close();
  }
  log(`screenshots in ${OUT}`);
  process.exitCode = failed ? 1 : 0;
})();
