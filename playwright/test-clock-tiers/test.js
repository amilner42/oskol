/**
 * The clock tiers on the guest home's sentence, at four sizes: "Play [a
 * match to 7] against [a friend] with [a standard clock]", and under it what
 * the clock is worth for the format ("14 min each for this 7-point match").
 * Changing the format rewrites that line and moves nothing: the sentence,
 * the line and the button hold their boxes. Then an account's PLAY dialog
 * (the tiers by name, the summary per mode, START GAME held), and the lobby
 * and the invite of a Standard match to 7. Shoots each of them.
 *
 *   node playwright/test-clock-tiers/test.js   # screenshots/test-clock-tiers/*.png
 */
const fs = require('fs');
const playwright = require('playwright');
const { execSync } = require('child_process');
const { createGame, openHome, openCreateDialog, pickWord, resultLine, seatedContext } = require('../lib/flows');

const OUT = 'playwright/screenshots/test-clock-tiers';
const SIZES = [
  ['390x844', 390, 844],
  ['320x568', 320, 568],
  ['844x390', 844, 390],
  ['1440x900', 1440, 900],
];
// Standard, format by format: what the line under the sentence says.
const LINES = [
  ['match7', '14 min each for this 7-point match'],
  ['single', '5 min each for this game'],
  ['match3', '6 min each for this 3-point match'],
  ['match21', '42 min each for this 21-point match'],
  ['unlimited', '5 min each per game'],
  ['match11', '22 min each for this 11-point match'],
];

function fail(message) {
  throw new Error(message);
}

async function box(page, selector) {
  const b = await page.locator(selector).boundingBox();
  if (!b) fail(`${selector} has no box`);
  return b;
}

function same(a, b, keys) {
  return keys.every((k) => Math.abs(a[k] - b[k]) < 0.5);
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await playwright.chromium.launch({ executablePath: process.env.PW_CHROMIUM || undefined });

  for (const [name, width, height] of SIZES) {
    const page = await browser.newPage({ viewport: { width, height } });
    await openHome(page);
    await pickWord(page, 'who', 'pick-who-friend');
    await pickWord(page, 'clock', 'pick-clock-bg_standard');
    if ((await page.textContent('#pick-clock')).trim() !== 'a standard clock') fail('the sentence does not name the tier');

    let held = null;
    for (const [format, line] of LINES) {
      await pickWord(page, 'game', `pick-game-${format}`);
      const note = (await page.textContent('#clock-note')).trim();
      if (note !== line) fail(`${name} ${format}: the line says "${note}", not "${line}"`);
      const boxes = {
        sentence: await box(page, '#sentence'),
        note: await box(page, '#clock-note'),
        roll: await box(page, '#roll-dice'),
      };
      // The line fits the screen, and nothing above or below it moved.
      if (boxes.note.x < 0 || boxes.note.x + boxes.note.width > width) fail(`${name} ${format}: the line runs off the screen`);
      if (boxes.note.y + boxes.note.height > boxes.roll.y) fail(`${name} ${format}: the line runs into the button`);
      if (held) {
        if (!same(held.sentence, boxes.sentence, ['y', 'height'])) fail(`${name} ${format}: the sentence moved`);
        if (!same(held.note, boxes.note, ['y', 'height'])) fail(`${name} ${format}: the line moved`);
        if (!same(held.roll, boxes.roll, ['x', 'y', 'width', 'height'])) fail(`${name} ${format}: the button moved`);
      } else {
        held = boxes;
      }
      if (format === 'match7' || format === 'unlimited') {
        await page.screenshot({ path: `${OUT}/${name}-${format}.png` });
      }
    }

    // No clock: the line empties and keeps its place.
    await pickWord(page, 'clock', 'pick-clock-none');
    if ((await page.textContent('#clock-note')).trim() !== '') fail(`${name}: no clock still has a line`);
    const empty = await box(page, '#roll-dice');
    if (!same(held.roll, empty, ['x', 'y', 'width', 'height'])) fail(`${name}: the button moved with no clock`);

    // The menu: five choices, every tier with its minutes for the format.
    await pickWord(page, 'game', 'pick-game-match7');
    await page.click('#pick-clock');
    await page.waitForSelector('#pick-clock-menu');
    const options = await page.$$eval('#pick-clock-menu [role=option]', (els) => els.map((e) => e.innerText.replace(/\s+/g, ' ').trim()));
    const expected = [
      'no clock',
      'a bullet clock 7 min each for this 7-point match',
      'a blitz clock 10.5 min each for this 7-point match',
      'a standard clock 14 min each for this 7-point match',
      'a classic clock 21 min each for this 7-point match',
    ];
    if (JSON.stringify(options) !== JSON.stringify(expected)) fail(`${name}: the menu reads ${JSON.stringify(options)}`);
    await page.screenshot({ path: `${OUT}/${name}-menu.png` });
    await page.click('#pick-clock-bg_classic');
    await page.waitForSelector('#pick-clock-menu', { state: 'detached' });

    // The friend dialog says the tier and what it is worth.
    await page.click('#roll-dice');
    await page.waitForSelector('#friend-modal');
    const sub = (await page.textContent('#friend-modal .lh-dlg-sub')).trim();
    if (!sub.startsWith('A match to 7 with a classic clock, 21 min each for this 7-point match.')) fail(`${name}: the dialog says "${sub}"`);
    await page.screenshot({ path: `${OUT}/${name}-dialog.png` });
    await page.close();
    console.log(`ok ${name}`);
  }

  // An account's PLAY dialog: the tiers by name in CLOCK, and the line
  // under the dropdowns says what the pick is worth for the mode.
  const { guest_id: guestId } = JSON.parse(
    resultLine(
      execSync(
        `mix run -e 'Logger.configure(level: :warning); u = Oskol.Auth.find_or_create_user("clock-tiers@oskol.test"); Oskol.Auth.claim_name(u.id, "ClockTiers"); g = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false); :ok = Oskol.Auth.bind_guest(g, u.id); IO.puts(Jason.encode!(%{guest_id: g}))'`,
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }
      )
    )
  );
  for (const [name, width, height] of SIZES) {
    const context = await seatedContext(browser, guestId, { viewport: { width, height } });
    const page = await context.newPage();
    await openCreateDialog(page);
    const labels = await page.$$eval('#create-clock option', (els) => els.map((e) => e.textContent.trim()));
    if (JSON.stringify(labels) !== JSON.stringify(['No clock', 'Bullet', 'Blitz', 'Standard', 'Classic'])) fail(`${name}: CLOCK lists ${JSON.stringify(labels)}`);
    await page.selectOption('#create-clock', 'bg_standard');
    let held = null;
    for (const [format, line] of LINES) {
      await page.selectOption('#create-mode', format);
      const summary = (await page.textContent('#create-summary')).trim();
      if (!summary.includes(`Standard · ${line}, 12 s delay every turn.`)) fail(`${name} ${format}: the summary says "${summary}"`);
      const boxes = { summary: await box(page, '#create-summary'), go: await box(page, '#create-game') };
      if (held) {
        if (!same(held.summary, boxes.summary, ['y', 'height'])) fail(`${name} ${format}: the summary moved or grew`);
        if (!same(held.go, boxes.go, ['x', 'y', 'width', 'height'])) fail(`${name} ${format}: START GAME moved`);
      } else {
        held = boxes;
      }
      if (format === 'match7') await page.screenshot({ path: `${OUT}/${name}-account.png` });
      // Every other clock for this mode holds the same box too.
      for (const clock of ['none', 'bg_bullet', 'bg_blitz', 'bg_classic', 'bg_standard']) {
        await page.selectOption('#create-clock', clock);
        if (!same(held.summary, await box(page, '#create-summary'), ['y', 'height'])) fail(`${name} ${format} ${clock}: the summary moved or grew`);
        if (!same(held.go, await box(page, '#create-game'), ['x', 'y', 'width', 'height'])) fail(`${name} ${format} ${clock}: START GAME moved`);
      }
    }
    await context.close();
    console.log(`ok ${name} account`);
  }

  // The lobby and the invite name the tier and its minutes for the match.
  for (const [name, width, height] of SIZES.slice(0, 2)) {
    const creator = await browser.newPage({ viewport: { width, height } });
    const game = await createGame(creator, { name: 'Alice', mode: 'match7', clock: 'bg_standard' });
    await creator.screenshot({ path: `${OUT}/${name}-lobby.png` });
    const lobby = await creator.textContent('body');
    if (!lobby.includes('Match to 7 · Standard clock · 14 min each')) fail(`${name}: the lobby does not name the clock`);
    const friend = await browser.newPage({ viewport: { width, height } });
    await friend.goto(game.inviteUrl);
    await friend.waitForSelector('#join-name, #join-game, button');
    await friend.waitForTimeout(500);
    await friend.screenshot({ path: `${OUT}/${name}-invite.png` });
    const invite = await friend.textContent('body');
    if (!invite.includes('Match to 7 · Standard clock · 14 min each')) fail(`${name}: the invite does not name the clock`);
    await creator.close();
    await friend.close();
    console.log(`ok ${name} lobby and invite`);
  }

  await browser.close();
}

main().catch((err) => {
  console.error('FAIL', err.message);
  process.exit(1);
});
