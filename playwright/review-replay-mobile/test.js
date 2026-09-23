/**
 * Screenshots of the replay on phones and a desktop, for eyeballing the
 * one-panel layout: at 390x844, 320x568, 844x390 and 1440x900, the MOVE
 * tab on a graded turn, the ANALYSIS tab and the MOVES tab. The phones are
 * shot whole (the page scrolls), the desktop as the window shows it.
 *
 * The room is arranged by the replay smoke's `setup.exs` and the analysis
 * is stubbed the way the smoke stubs it (`lib/replay-stub.js`), so no
 * engine is needed. Run with the server up:
 *   node playwright/review-replay-mobile/test.js [out-dir]
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { resultLine } = require('../lib/flows');
const { stubAnalysis } = require('../lib/replay-stub');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const OUT = process.argv[2] || 'playwright/screenshots/review-replay-mobile';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SCREENS = [
  { name: 'phone-390x844', width: 390, height: 844, phone: true },
  { name: 'phone-320x568', width: 320, height: 568, phone: true },
  { name: 'landscape-844x390', width: 844, height: 390, phone: true },
  { name: 'desktop-1440x900', width: 1440, height: 900, phone: false },
];

function arrangeRoom() {
  if (process.env.REPLAY_JSON) return JSON.parse(process.env.REPLAY_JSON);
  log('arranging a finished match (mix run playwright/test-backgammon-replay/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-replay/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  return JSON.parse(resultLine(out));
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const room = arrangeRoom();
  const alice = room.players[0];
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM || undefined, args: ['--no-sandbox'] });
  try {
    const api = await playwright.request.newContext({ extraHTTPHeaders: { cookie: `_oskol_guest=${alice.guest}` } });
    const record = (await (await api.get(`${BASE}/papi/games/backgammon/rooms/${room.game_id}/record`)).json()).record;
    const last = record.games[record.games.length - 1];
    for (const screen of SCREENS) {
      const ctx = await browser.newContext({
        viewport: { width: screen.width, height: screen.height },
        isMobile: screen.phone, hasTouch: screen.phone, deviceScaleFactor: screen.phone ? 2 : 1,
      });
      await ctx.addCookies([{ name: '_oskol_guest', value: alice.guest, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      // The analysis is done from the first ask (`get: 5` is past pending).
      await stubAnalysis(ctx, record, { get: 5, retry: 0, game: 0 });
      const page = await ctx.newPage();
      await page.goto(`${BASE}/backgammon/${room.game_id}/replay?game=${last.number}`);
      await page.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
      await page.waitForSelector('#rp-note', { timeout: 20000 });
      await sleep(400);
      // A graded turn with candidates: step until the table is there.
      for (let i = 0; i < 12 && !(await page.locator('.rp-cand:not(.is-played)').count()); i++) {
        await page.click('#rp-next');
        await sleep(150);
      }
      await page.click('#rp-note-move');
      await sleep(300);
      const shot = async (what) => {
        await page.screenshot({ path: `${OUT}/${screen.name}-${what}.png`, fullPage: screen.phone });
        log(`${screen.name}: ${what}`);
      };
      await shot('1-move');
      await page.click('#rp-tab-analysis');
      await sleep(300);
      await shot('2-analysis');
      await page.click('#rp-tab-moves');
      await sleep(400);
      await shot('3-moves');
      await ctx.close();
    }
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
