/**
 * Screenshots of the replay on phones and a desktop, for eyeballing the
 * one-panel side: at 390x844, 320x568, 844x390 and 1440x900, MOVE on a
 * graded turn (the verdict), CUBE on it, OVERVIEW as a guest (the
 * practice line with its "Sign in", then opened), and OVERVIEW signed in
 * (the mistakes are in your practice already). The phones are shot whole
 * (the page scrolls), the desktop as the window shows it.
 *
 * The room is arranged by the replay smoke's `setup.exs`; the analysis is
 * stubbed the way the smoke stubs it (`lib/replay-stub.js`), the game's
 * mistakes (`/puzzles?game=n`) are two made-up ids, and the signed-in
 * pass answers `/papi/me` with an account, so no engine and no mail are
 * needed. Run with the server up:
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
    const open = async (screen, { signedIn }) => {
      const ctx = await browser.newContext({
        viewport: { width: screen.width, height: screen.height },
        isMobile: screen.phone, hasTouch: screen.phone, deviceScaleFactor: screen.phone ? 2 : 1,
      });
      await ctx.addCookies([{ name: '_oskol_guest', value: alice.guest, url: BASE, httpOnly: true, sameSite: 'Lax' }]);
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
      // The analysis is done from the first ask (`get: 5` is past pending).
      await stubAnalysis(ctx, record, { get: 5, retry: 0, game: 0 });
      // The game's mistakes, counted: two, so the overview has its line.
      await ctx.route(/\/papi\/games\/backgammon\/rooms\/[^/]+\/puzzles\?game=\d+/, (route) =>
        route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({
          ok: true, puzzles: [{ id: 'aaaaaaaa', kind: 'move', prompt: '', due: false }, { id: 'bbbbbbbb', kind: 'cube', prompt: '', due: false }], counts: null, mistakes: null,
        }) }));
      if (signedIn) {
        await ctx.route(/\/papi\/me(\?|$)/, (route) =>
          route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, guest_name: 'Alice', user: { email: 'alice@oskol.test', name: 'alice' } }) }));
      }
      return ctx;
    };
    for (const screen of SCREENS) {
      const ctx = await open(screen, { signedIn: false });
      const page = await ctx.newPage();
      await page.goto(`${BASE}/backgammon/${room.game_id}/replay?game=${last.number}`);
      await page.waitForSelector('.bg-still .bg-board', { timeout: 20000 });
      await page.waitForSelector('#rp-panel, #rp-note', { timeout: 20000 });
      await sleep(400);
      // A graded turn with candidates: step until the table is there.
      for (let i = 0; i < 12 && !(await page.locator('.rp-cand:not(.is-played)').count()); i++) {
        await page.click('#rp-next');
        await sleep(150);
      }
      await sleep(300);
      const shot = async (what) => {
        await page.screenshot({ path: `${OUT}/${screen.name}-${what}.png`, fullPage: screen.phone });
        log(`${screen.name}: ${what}`);
      };
      await shot('1-verdict');
      await page.click('#rp-note-cube');
      await sleep(300);
      await shot('2-cube');
      await page.click('#rp-first');
      await sleep(300);
      await shot('3-overview');
      await page.click('#rp-deck-signin-open');
      await page.waitForSelector('#rp-deck-signin #signin', { timeout: 2000 });
      await sleep(300);
      await shot('4-overview-signin-open');
      await ctx.close();

      const kept = await open(screen, { signedIn: true });
      const p2 = await kept.newPage();
      await p2.goto(`${BASE}/backgammon/${room.game_id}/replay?game=${last.number}`);
      await p2.waitForSelector('#rp-deck.is-kept', { timeout: 20000 });
      await sleep(400);
      await p2.screenshot({ path: `${OUT}/${screen.name}-5-overview-signed-in.png`, fullPage: screen.phone });
      log(`${screen.name}: 5-overview-signed-in`);
      await kept.close();
    }
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
