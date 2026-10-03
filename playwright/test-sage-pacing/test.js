/**
 * Sage's turn, paced so a person can follow it: its dice tumble and land,
 * Sage thinks (the dot by its name), and only then do its checkers move,
 * one by one: each move Sage stages reaches the person as a ghost (the
 * scene's staging layer) before its PLAY commits the lot.
 *
 * The pacing is the server's (`Oskol.Game.Bot`, `config :oskol, :bot`), so
 * this watches what every browser sees: a guest plays a single game against
 * Sage with a stand-in engine that answers at once (engine.exs, on
 * ANALYSIS_STUB_PORT: whatever holds Sage back is the pacing, not a think),
 * plays its own turns, and records every animation frame of Sage's: whether
 * any die is still animating, where every checker stands, and whether the
 * think dot is lit. It fails if a checker moves while a die is still in the
 * air or inside the tumble, or the dot goes out before the play, and prints
 * the timing of the turn it measured.
 *
 * Run with the server up (its ANALYSIS_URL pointing at the stand-in's port,
 * as bin/check --browser sets it):
 *   node playwright/test-sage-pacing/test.js
 */
const playwright = require('playwright');
const { spawn } = require('child_process');
const { BASE, createGame } = require('../lib/flows');

const STUB_PORT = Number(process.env.ANALYSIS_STUB_PORT || Number(new URL(BASE).port || 80) + 10000);
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The roll's own animation (`.die.rolling`: the reel lands at 0.95 s). A
// first checker sooner than this after the throw is a checker under the dice.
const TUMBLE_MS = 950;

/** The stand-in engine, listening, and a way to stop it. */
async function startEngine() {
  log(`starting the stand-in engine on ${STUB_PORT}`);
  const child = spawn('mix', ['run', '--no-start', '-e', 'Code.eval_file("playwright/test-sage-pacing/engine.exs")'], {
    env: { ...process.env, ANALYSIS_STUB_PORT: String(STUB_PORT), MIX_ENV: process.env.MIX_ENV || 'dev' },
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  const stop = () => { try { child.stdin.end(); } catch (_) {} try { child.kill(); } catch (_) {} };
  process.on('exit', stop);
  await new Promise((resolve, reject) => {
    let out = '';
    child.stdout.on('data', (d) => {
      out += d;
      if (/"engine"/.test(out)) resolve();
    });
    child.on('exit', (code) => reject(new Error(`the stand-in engine stopped (${code}):\n${out.slice(-2000)}`)));
  });
  return stop;
}

/** Is it the person's turn: a ROLL to press, or checkers to move? */
async function myTurn(page) {
  return (await page.$('button:has-text("ROLL"), .bg-point.source')) !== null;
}

/** Play the person's turn: roll if asked, move what the board offers, PLAY. */
async function playMyTurn(page) {
  const roll = await page.$('button:has-text("ROLL")');
  if (roll) {
    await roll.click();
    await sleep(1300);
  }
  for (let i = 0; i < 4; i += 1) {
    const src = page.locator('.bg-point.source');
    if ((await src.count()) === 0) break;
    const used = await page.locator('.die.used').count();
    await src.first().click();
    try {
      await page.waitForFunction((n) => document.querySelectorAll('.die.used').length > n, used, { timeout: 3000 });
    } catch (_) {
      break;
    }
  }
  await page.waitForSelector('#bg-action-play', { timeout: 5000 });
  await page.click('#bg-action-play');
}

/**
 * Record every frame from now: when, whether any die is animating, and the
 * board as a string of where every checker stands. Stopped by `stopFrames`.
 */
async function startFrames(page) {
  await page.evaluate(() => {
    const frames = [];
    window.__frames = frames;
    window.__recording = true;
    const board = () =>
      [...document.querySelectorAll('.bg-point')]
        .map((p) => [...p.querySelectorAll('.checker')].map((c) => (c.classList.contains('white') ? 'w' : 'b') + (c.textContent || '')).join(''))
        .join('|');
    const diceMoving = () =>
      [...document.querySelectorAll('.die')].some((d) =>
        d.getAnimations({ subtree: true }).some((a) => a.playState === 'running'),
      );
    const tick = () => {
      if (!window.__recording) return;
      frames.push({
        t: performance.now(),
        dice: diceMoving(),
        board: board(),
        thinking: document.querySelector('.bar-dot.thinking') !== null,
        ghosts: document.querySelectorAll('.checker.ghost').length,
      });
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

async function stopFrames(page) {
  return page.evaluate(() => {
    window.__recording = false;
    return window.__frames;
  });
}

/**
 * Sage's turn as the frames saw it: when its dice started tumbling, when
 * they stopped, and when each of its checker moves landed. Null when its
 * dice never moved in these frames, or no checker did (a dance).
 */
function sagesTurn(frames) {
  const thrown = frames.findIndex((f) => f.dice);
  if (thrown < 0) return null;
  const before = frames[thrown].board;
  const landed = frames.findIndex((f, i) => i > thrown && !f.dice);
  const moves = [];
  let board = before;
  frames.forEach((f, i) => {
    if (i > thrown && f.board !== board) {
      moves.push(f);
      board = f.board;
    }
  });
  if (moves.length === 0) return null;
  return { thrown: frames[thrown], landed: landed < 0 ? null : frames[landed], moves, frames };
}

async function main() {
  const stopEngine = await startEngine();
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));

  try {
    const game = await createGame(page, { name: 'Alice', opponent: 'bot' });
    log(`game ${game.gameId} against Sage`);

    // Sage may hold the opening roll, dealt with the game rather than
    // thrown: wait for the person's first turn and measure from there.
    let measured = null;
    for (let turn = 0; turn < 6 && !measured; turn += 1) {
      await page.waitForSelector('button:has-text("ROLL"), .bg-point.source', { timeout: 60000 });
      // Let the person's own dice and checkers come to rest first.
      await sleep(1500);
      await playMyTurn(page);
      await startFrames(page);
      await page.waitForFunction(
        () => document.querySelector('.bg-point.source') !== null || [...document.querySelectorAll('button')].some((b) => /ROLL/.test(b.textContent)),
        null,
        { timeout: 60000 },
      );
      const frames = await stopFrames(page);
      measured = sagesTurn(frames);
      if (!measured) log(`turn ${turn + 1}: Sage had nothing to move; again`);
    }
    if (!measured) throw new Error('Sage never moved a checker in six turns');

    const { thrown, landed, moves } = measured;
    const first = moves[0];
    const gaps = moves.slice(1).map((m, i) => Math.round(m.t - moves[i].t));
    log(
      `Sage's turn: dice in the air ${Math.round((landed ? landed.t : NaN) - thrown.t)} ms, ` +
        `first checker ${Math.round(first.t - thrown.t)} ms after the throw, ` +
        `then ${gaps.length ? gaps.join(', ') + ' ms apart' : 'no more'}`,
    );

    if (first.dice) throw new Error('a checker of Sage moved while its dice were still in the air');
    if (!landed || landed.t > first.t) throw new Error('Sage moved before its dice had landed');
    if (first.t - thrown.t < TUMBLE_MS) {
      throw new Error(`Sage's first checker came ${Math.round(first.t - thrown.t)} ms after the throw, inside the ${TUMBLE_MS} ms tumble`);
    }
    // Between the dice landing and the play, Sage is seen thinking.
    const between = measured.frames.filter((f) => f.t >= landed.t && f.t < first.t);
    if (!between.length || !between.every((f) => f.thinking)) {
      throw new Error("Sage's think dot was not lit between its dice landing and its play");
    }
    // Sage's staging is seen as it happens: at least one frame between its
    // roll and its play shows a staged checker as a ghost, and the play
    // takes every ghost away.
    const staged = measured.frames.filter((f) => f.ghosts > 0);
    if (!staged.length) throw new Error("the person never saw one of Sage's staged moves before its play");
    if (measured.frames[measured.frames.length - 1].ghosts !== 0) throw new Error("Sage's ghosts outlived its play");
    log(`saw Sage's staging for ${Math.round(staged[staged.length - 1].t - staged[0].t)} ms, up to ${Math.max(...staged.map((f) => f.ghosts))} ghost(s)`);
    if (errors.length) throw new Error(errors.join('\n'));
    log('SAGE PACING OK');
  } finally {
    await browser.close();
    stopEngine();
  }
}

main().catch((e) => {
  console.error('SAGE PACING FAILED:', e.message);
  process.exit(1);
});
