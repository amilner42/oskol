/**
 * A danced turn, the roll animation, and the turn delay on a clock.
 *
 * The room is arranged by `setup.exs` (which finds a seed that dances and
 * replays it into a real, persisted room) and handed here as JSON in
 * DANCE_JSON. Opening it makes the server rehydrate the room from its
 * action log, so this also proves a game saved mid-dance reloads sanely.
 *
 *   mix run -e 'Code.eval_file("playwright/test-backgammon-dance/setup.exs")'
 *   DANCE_JSON='<the last line it printed>' node playwright/test-backgammon-dance/test.js
 *
 * 1. Both seats see the dice that danced and "NO LEGAL MOVES / TURN PASSES"
 * 2. Only the dancer has a button, and it says PASS TURN
 * 3. Pressing it hands the turn over; the message is gone for both
 * 4. The opponent's dice tumble on the way in (screenshot mid-roll)
 * 5. A fresh blitz game shows the twelve-second delay holding the clock
 */
const playwright = require('playwright');
const fs = require('fs');
const { execFileSync } = require('child_process');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4455}`;
const SHOTS = process.env.DANCE_SHOTS || 'playwright/screenshots/test-backgammon-dance';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function must(condition, message) {
  if (!condition) throw new Error(message);
  log(`ok: ${message}`);
}

/** The danced room: from DANCE_JSON, or by running the setup script here. */
function arrangeRoom() {
  if (process.env.DANCE_JSON) return JSON.parse(process.env.DANCE_JSON);
  log('arranging a danced room (mix run playwright/test-backgammon-dance/setup.exs)');
  const out = execFileSync(
    'mix',
    ['run', '-e', 'Code.eval_file("playwright/test-backgammon-dance/setup.exs")'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 }
  );
  const last = out.trim().split('\n').pop();
  return JSON.parse(last);
}

async function main() {
  const room = arrangeRoom();
  fs.mkdirSync(SHOTS, { recursive: true });

  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 860 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const seats = {};
    for (const player of room.players) {
      const page = await context.newPage();
      watch(page, player.name);
      await page.goto(`${BASE}/backgammon/${room.game_id}?t=${player.token}`);
      await page.waitForSelector('.bg-board', { timeout: 15000 });
      seats[player.id] = { page, name: player.name };
    }
    log(`room ${room.game_id} rehydrated from its log (${room.steps} actions, seed ${room.seed})`);

    const dancer = seats[room.dancer];
    const other = Object.entries(seats).find(([id]) => id !== room.dancer)[1];

    // 1 + 2: the state is rendered for both, the button only for the mover.
    await dancer.page.waitForSelector('#bg-no-moves', { timeout: 10000 });
    await other.page.waitForSelector('#bg-no-moves', { timeout: 10000 });
    const mine = await dancer.page.textContent('#bg-no-moves');
    const theirs = await other.page.textContent('#bg-no-moves');
    must(/NO LEGAL MOVES/.test(mine) && /TURN PASSES/.test(mine), `the dancer reads "${mine.trim()}"`);
    must(
      /HAS NO LEGAL MOVES/.test(theirs) && /TURN PASSES/.test(theirs),
      `the opponent reads "${theirs.trim()}"`
    );
    const dice = await dancer.page.locator('.die').count();
    must(dice > 0, `the dice that danced are on the board (${dice} of them)`);
    // The room came out of its log: the throw happened while nobody was
    // looking here, so the dice are simply on the table.
    must(
      (await dancer.page.locator('.die-tumble').count()) === 0 &&
        (await other.page.locator('.die-tumble').count()) === 0,
      'a rehydrated room does not replay the roll to anyone'
    );
    // And opening your own seat link is not somebody taking your seat.
    must(
      !(await dancer.page.locator('#play-error').count()) && !(await dancer.page.locator('#game-gone').count()),
      'opening the seat link says nothing about the seat being opened elsewhere'
    );
    must(await dancer.page.locator('#bg-action-play').count(), 'the dancer has the pass button');
    must(!(await other.page.locator('#bg-action-play').count()), 'the opponent has nothing to press');
    const label = await dancer.page.textContent('#bg-action-play');
    must(/PASS TURN/.test(label), `the button reads "${label.trim()}"`);

    await dancer.page.screenshot({ path: `${SHOTS}/dance-mover.png` });
    await other.page.screenshot({ path: `${SHOTS}/dance-opponent.png` });

    // 3 + 4: passing hands the turn over, and the incoming roll tumbles.
    await dancer.page.click('#bg-action-play');
    await sleep(220);
    await other.page.screenshot({ path: `${SHOTS}/dice-rolling.png` });
    const rolling = await other.page.locator('.die.rolling .die-tumble').count();
    must(rolling > 0, `the new roll is tumbling (${rolling} dice mid-animation)`);
    await sleep(1200);
    must(!(await dancer.page.locator('#bg-no-moves').count()), 'the message is gone once the turn passed');
    await other.page.screenshot({ path: `${SHOTS}/dice-settled.png` });

    // 5: a reload mid-turn resumes quietly -- the dice that were already
    // thrown are on the table, and nobody is told they lost the seat.
    await other.page.reload();
    await other.page.waitForSelector('.bg-board', { timeout: 15000 });
    await sleep(400);
    must(
      (await other.page.locator('.die').count()) > 0,
      'a reload mid-turn comes back to the same dice'
    );
    must(
      (await other.page.locator('.die-tumble').count()) === 0,
      'a reload does not throw the dice again'
    );
    must(
      !(await other.page.locator('#play-error').count()) && !(await other.page.locator('#game-gone').count()),
      'a reload resumes without a word about the seat'
    );
    await other.page.screenshot({ path: `${SHOTS}/reload-settled.png` });

    // A phone going to sleep and waking up: the socket drops and comes
    // back, which is the same tab, not a new player.
    await context.setOffline(true);
    await sleep(800);
    await context.setOffline(false);
    await other.page.waitForFunction(
      () => !document.body.textContent.includes('RECONNECTING'),
      null,
      { timeout: 20000 }
    );
    await sleep(600);
    must(
      !(await other.page.locator('#play-error').count()) && !(await other.page.locator('#game-gone').count()),
      'a dropped socket coming back is the same player, not a takeover'
    );
    must(
      (await other.page.locator('.die-tumble').count()) === 0,
      'and it does not throw the dice again either'
    );

    // The seat still knows a real takeover when it sees one: another
    // browser (its own context, its own socket) on the same link, and the
    // one that had the seat is the one that hears about it.
    const otherBrowser = await browser.newContext({ viewport: { width: 1280, height: 860 } });
    const secondTab = await otherBrowser.newPage();
    const seatUrl = other.page.url();
    await secondTab.goto(seatUrl);
    await secondTab.waitForSelector('.bg-board', { timeout: 15000 });
    await other.page.waitForSelector('#play-error, #game-gone', { timeout: 10000 });
    const toast = await other.page.textContent('#play-error, #game-gone');
    must(/somewhere else/i.test(toast) || /GONE/i.test(toast), `the old connection is told: "${toast.trim()}"`);
    must(
      !(await secondTab.locator('#play-error').count()),
      'the browser that took the seat is playing, not apologising'
    );
    await other.page.screenshot({ path: `${SHOTS}/taken-over.png` });
    await otherBrowser.close();

    // 6: a fresh game on a clock, showing the delay.
    const p1 = await context.newPage();
    watch(p1, 'clock-p1');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('#create-name');
    await p1.fill('input[name="player_name"]', 'Ada');
    await p1.click('#clock-blitz');
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const timedId = new URL(p1.url()).pathname.split('/')[2];

    const p2 = await context.newPage();
    watch(p2, 'clock-p2');
    await p2.goto(`${BASE}/backgammon?game=${timedId}`);
    await p2.waitForSelector('#join-game');
    await p2.fill('input[name="player_name"]', 'Bo');
    await p2.click('#join-game');
    await p1.waitForSelector('.bg-board', { timeout: 15000 });
    await p2.waitForSelector('.bg-board', { timeout: 15000 });

    const mover = (await p1.locator('#bg-action-play, .bg-point.source').count()) ? p1 : p2;
    // Two pips: the player's bar (phones) and the desktop rail. Only the
    // rail's is visible at this width.
    const pipEl = mover.locator('.delay-pip').last();
    await pipEl.waitFor({ timeout: 10000 });
    const pip = (await pipEl.textContent()).trim();
    must(/^\+\d+$/.test(pip), `the mover's clock is held, ${pip} s of delay left`);
    await mover.screenshot({ path: `${SHOTS}/clock-delay.png` });

    // Wait the delay out: the clock starts moving and the pip goes away.
    // The bar of the player to act -- theirs is the clock that runs.
    const clock = mover.locator('.player-bar.active .clock-chip .tabular-nums').first();
    const before = await clock.textContent();
    await sleep(13000);
    must(!(await mover.locator('.delay-pip').count()), 'the delay is spent and the pip is gone');
    const after = await clock.textContent();
    must(before !== after, `the clock only started moving after the delay (${before.trim()} -> ${after.trim()})`);
    await mover.screenshot({ path: `${SHOTS}/clock-running.png` });

    if (errors.length) throw new Error(`page errors:\n${errors.join('\n')}`);
    log('PASS');
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
