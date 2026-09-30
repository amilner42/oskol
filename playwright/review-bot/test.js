/**
 * Screenshots of a game against Sage: the dialog with the bot picked, and the
 * table with Sage across it -- the chip badge beside the name, and the
 * presence dot pulsing while the engine reads the position. Needs an engine
 * (fly proxy on 18082), because the point is what a real think looks like.
 *
 *   node playwright/review-bot/test.js
 */
const playwright = require('playwright');
const { BASE, createGame } = require('../lib/flows');
const OUT = process.argv[2] || 'playwright/screenshots/review-bot';
const fs = require('fs');
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM,
    args: ['--no-sandbox'],
  });

  for (const [name, vp] of [
    ['desktop', { width: 1280, height: 900 }],
    ['phone', { width: 390, height: 844 }],
    ['narrow', { width: 320, height: 720 }],
  ]) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
    await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await ctx.newPage();

    const game = await createGame(page, { name: 'Alice', mode: 'match5', opponent: 'bot' });
    console.log(`${name}: ${game.url}`);
    await sleep(1500);
    await page.screenshot({ path: `${OUT}/${name}-01-table.png`, fullPage: true });

    // Whoever the opening roll fell to, wait for the person's turn, roll,
    // play the checkers the board offers and commit. The shot after that is
    // Sage reading the position.
    // The opening roll is dealt with the game, so the person may already be
    // in the middle of a turn rather than waiting to roll.
    await page.waitForSelector('button:has-text("ROLL"), .bg-point.source', { timeout: 120000 });
    await page.screenshot({ path: `${OUT}/${name}-02-my-turn.png`, fullPage: true });
    const roll = await page.$('button:has-text("ROLL")');
    if (roll) {
      await roll.click();
      await sleep(1200);
    }

    for (let i = 0; i < 4; i += 1) {
      const src = page.locator('.bg-point.source');
      if ((await src.count()) === 0) break;
      const used = await page.locator('.die.used').count();
      await src.first().click();
      try {
        await page.waitForFunction(
          (n) => document.querySelectorAll('.die.used').length > n,
          used,
          { timeout: 3000 },
        );
      } catch (_) {
        break;
      }
      await sleep(300);
    }
    await page.screenshot({ path: `${OUT}/${name}-03-staged.png`, fullPage: true });
    const play = await page.$('#bg-action-play');
    if (play) await play.click();

    // Sage is on it now: the badge beside its name, and the dot under way.
    await sleep(1500);
    await page.screenshot({ path: `${OUT}/${name}-04-sage-thinking.png`, fullPage: true });

    // A screenshot cannot show an animation, so say what the classes are.
    const marks = await page.evaluate(() =>
      [...document.querySelectorAll('.player-bar')].map((bar) => ({
        name: bar.querySelector('.font-bold')?.textContent,
        badge: bar.querySelector('.identity-icon')?.dataset.identity ?? null,
        dot: bar.querySelector('.bar-dot')?.className ?? null,
      })),
    );
    console.log(`${name} bars: ${JSON.stringify(marks)}`);
    await ctx.close();
  }

  await browser.close();
})();
