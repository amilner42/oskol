/**
 * The screens landscape focus mode must NOT touch, shot on a seeded room so
 * that the position is the same every run: portrait phones, a tablet either
 * way up, a desktop, and the replay of a finished match on each.
 *
 * It proves nothing on its own -- it is the fixture for a two-run diff. Run
 * it once against the branch and once against main's stylesheet, and the two
 * directories must come out byte for byte the same:
 *
 *     mix oskol.seed
 *     node playwright/review-landscape-focus/unchanged.js /tmp/after
 *     ...put main's assets/css/app.css back, mix assets.build...
 *     node playwright/review-landscape-focus/unchanged.js /tmp/before
 *     diff -rq /tmp/before /tmp/after
 *
 * The seat is claimed once from the invite (a seeded room's seats are held
 * by nobody) under a fixed guest id, so the second run opens the same seat
 * rather than arriving as a stranger.
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, seatedContext } = require('../lib/flows');

const OUT = process.argv[2];
const ROOM = process.argv[3] || '000001';
const REPLAY_ROOM = process.argv[4] || '000011';
// A puzzle, if the caller has one: `mix run -e
// 'Code.eval_file("playwright/test-puzzle/setup.exs")'` prints two, and its
// ids are a hash of a seeded position, so they are the same every time.
const PUZZLE = process.argv[5] || process.env.PUZZLE_ID;
const GUEST = 'AAAABBBBCCCCDDDDEEEEFF'; // 22 chars: the shape the guest plug keeps
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SIZES = [
  ['portrait-390x844', 390, 844],
  ['portrait-320x720', 320, 720],
  ['tablet-768x1024', 768, 1024],
  ['tablet-1024x768', 1024, 768],
  ['desktop-1440x900', 1440, 900],
  ['desktop-1280x800', 1280, 800],
];

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  // Claim the seat once; every size afterwards is the same browser's.
  const first = await seatedContext(browser, GUEST, { viewport: { width: 1280, height: 800 } });
  const fp = await first.newPage();
  await fp.goto(`${BASE}/backgammon/${ROOM}`);
  await fp.waitForTimeout(1500);
  if (!(await fp.locator('.bg-board').count())) {
    // A seeded room's seats are held by nobody: take the first from the
    // invite, which is what the seeds are for.
    await fp.goto(`${BASE}/backgammon?game=${ROOM}`);
    await fp.waitForSelector('[id^="reclaim-"]', { timeout: 20000 });
    await fp.locator('[id^="reclaim-"]').first().click();
  }
  await fp.waitForSelector('.bg-board', { timeout: 20000 });
  await first.close();

  for (const [name, width, height] of SIZES) {
    const c = await seatedContext(browser, GUEST, {
      viewport: { width, height },
      deviceScaleFactor: 1,
      reducedMotion: 'reduce',
    });
    await c.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const p = await c.newPage();
    await p.goto(`${BASE}/backgammon/${ROOM}`);
    await p.waitForSelector('.bg-board', { timeout: 20000 });
    await sleep(1800);
    await p.screenshot({ path: `${OUT}/${name}-table.png` });
    await p.goto(`${BASE}/backgammon/${REPLAY_ROOM}/replay`);
    await p.waitForSelector('.bg-still, .rp-message', { timeout: 20000 });
    await sleep(1800);
    await p.screenshot({ path: `${OUT}/${name}-replay.png` });
    if (PUZZLE) {
      await p.goto(`${BASE}/puzzles/${PUZZLE}`);
      await p.waitForSelector('.bg-still, #pz-missing', { timeout: 20000 });
      await sleep(1800);
      await p.screenshot({ path: `${OUT}/${name}-puzzle.png` });
    }
    await c.close();
    console.log(name);
  }
  await browser.close();
})();
