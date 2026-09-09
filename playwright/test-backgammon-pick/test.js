/**
 * The "Pick dice" twist, at phone width.
 *
 * 1. /backgammon -> create a single game with the twist ON, second player joins
 * 2. The opening mover plays their turn; the other player then faces a real
 *    choice (ROLL or PICK DICE), so nothing auto-rolls
 * 3. Open the picker (screenshot), cancel, reopen, pick 6-6, confirm
 * 4. Both players see four dice with the PICKED tag; the picker's own PICK
 *    chip is gone while the opponent still shows theirs
 * 5. After the picked turn is played, the opponent still has PICK DICE; the
 *    player who used theirs never sees the button again
 *
 * Run with the server up:  node playwright/test-backgammon-pick/test.js
 */
const playwright = require('playwright');
const fs = require('fs');

const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;
const SHOTS = process.env.PICK_SHOTS || 'playwright/screenshots/test-backgammon-pick';
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function stageWholeTurn(mover) {
  const source = '.bg-point.source, .bg-bar:has(.checker.pick)';
  for (let i = 0; i < 5; i++) {
    const src = mover.locator(source);
    if ((await src.count()) === 0) break;
    await src.first().click();
    const target = mover.locator('.bg-point:has(.drop-ghost), .bg-tray:has(.drop-ghost)');
    try { await target.first().waitFor({ timeout: 3000 }); } catch (_) { break; }
    await target.first().click();
    await sleep(400);
  }
  const play = mover.locator('button:has-text("PLAY")');
  try {
    await play.waitFor({ timeout: 5000 });
    await play.click();
  } catch (_) {
    // A dance: the turn passed by itself.
  }
  await sleep(600);
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  // Phone-first: the whole flow runs at phone width.
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  const errors = [];
  const watch = (page, who) => {
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
  };

  try {
    const p1 = await context.newPage();
    watch(p1, 'p1');
    await p1.goto(`${BASE}/backgammon`);
    await p1.waitForSelector('#create-name');
    await p1.fill('input[name="player_name"]', 'Alice');
    // Single game, twist ON.
    await p1.click('#choice-twist-pick_dice');
    await p1.waitForSelector('#choice-twist-pick_dice.tile-mine');
    await p1.click('#create-game');
    await p1.waitForSelector('#share-link');
    const gameId = new URL(p1.url()).pathname.split('/')[2];
    log(`Game ${gameId} created with the twist on`);

    const p2 = await context.newPage();
    watch(p2, 'p2');
    await p2.goto(`${BASE}/backgammon?game=${gameId}`);
    await p2.waitForSelector('#join-game');
    await p2.fill('input[name="player_name"]', 'Bob');
    await p2.click('#join-game');
    await p1.waitForURL(`**/backgammon/${gameId}**`);
    await p2.waitForURL(`**/backgammon/${gameId}**`);
    log('Both players on the game page');

    // Both players still hold their pick: a PICK chip per identity bar.
    await p1.waitForSelector('.bg-has-pick', { timeout: 20000 });
    if ((await p1.locator('.bg-has-pick').count()) !== 2) throw new Error('both players should show a PICK chip');

    // The opening roll puts one player straight into Moving: play it out.
    const source = '.bg-point.source';
    await Promise.race([
      p1.waitForSelector(source, { timeout: 20000 }),
      p2.waitForSelector(source, { timeout: 20000 }),
    ]);
    const opener = (await p1.locator(source).count()) > 0 ? p1 : p2;
    const picker = opener === p1 ? p2 : p1;
    await stageWholeTurn(opener);
    log('Opening turn played');

    // Now the other player must choose: ROLL or PICK DICE. No auto-roll.
    await picker.waitForSelector('#pick-dice-open', { timeout: 10000 });
    if ((await picker.locator('button:has-text("ROLL")').count()) !== 1) {
      throw new Error('ROLL should be offered next to PICK DICE');
    }
    await picker.screenshot({ path: `${SHOTS}/01-choice.png` });

    // Open the picker, look at it, cancel, reopen and pick 6-6.
    await picker.click('#pick-dice-open');
    await picker.waitForSelector('#pick-dice-panel');
    await picker.click('#pick-face-6');
    await picker.screenshot({ path: `${SHOTS}/02-picker-open.png` });
    await picker.click('#pick-cancel');
    try {
      await picker.waitForSelector('#pick-dice-panel', { state: 'detached', timeout: 3000 });
    } catch (_) {
      throw new Error('cancel should close the picker');
    }
    await picker.click('#pick-dice-open');
    await picker.click('#pick-face-6');
    await picker.click('#pick-face-6');
    await picker.screenshot({ path: `${SHOTS}/03-picker-6-6.png` });
    await picker.click('#pick-confirm');
    log('Picked 6-6');

    // A doubles pick: four dice, marked PICKED on both boards.
    await picker.waitForSelector('#dice-picked-tag', { timeout: 10000 });
    const waiterView = opener;
    await waiterView.waitForSelector('#dice-picked-tag', { timeout: 10000 });
    const pickerDice = await picker.locator('.die:not(.mini)').count();
    if (pickerDice !== 4) throw new Error(`a 6-6 pick should show four dice, saw ${pickerDice}`);
    if ((await waiterView.locator('.die:not(.mini)').count()) !== 4) throw new Error('the opponent should see four picked dice');
    // Four moves are on the table for the picked doubles.
    const moveCount = await picker.evaluate(() => document.querySelectorAll('.bg-point.source, .drop-ghost').length);
    if ((await picker.locator(source).count()) === 0) throw new Error('the picked 6-6 should offer moves');
    log(`Picked dice give moves from ${moveCount} marked spots`);
    // The pick is spent: one PICK chip left on each page.
    if ((await picker.locator('.bg-has-pick').count()) !== 1) throw new Error('the used pick should drop its chip');
    await picker.screenshot({ path: `${SHOTS}/04-picked-dice.png` });
    await waiterView.screenshot({ path: `${SHOTS}/05-opponent-sees-picked.png` });

    // Play the picked turn out; the opponent still holds their pick.
    await stageWholeTurn(picker);
    await opener.waitForSelector('#pick-dice-open', { timeout: 10000 });
    log('Opponent still offered PICK DICE');
    // They roll instead; back on the picker's side the button is gone for good.
    await opener.click('button:has-text("ROLL DICE")');
    await stageWholeTurn(opener);
    await picker.waitForFunction(
      () => /rolling|moving/.test(document.body.textContent) || document.querySelector('.die'),
      null,
      { timeout: 10000 }
    );
    await sleep(1500); // auto-roll (no choice left) fires on the picker's turn
    if ((await picker.locator('#pick-dice-open').count()) !== 0) {
      throw new Error('the pick button must be gone after use');
    }
    await picker.screenshot({ path: `${SHOTS}/06-pick-gone.png` });

    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
    log('PICK DICE OK');
  } catch (e) {
    await Promise.all(context.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${i}.png` }).catch(() => {})));
    console.error('PICK DICE FAILED:', e.message);
    if (errors.length) console.error(errors.join('\n'));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
