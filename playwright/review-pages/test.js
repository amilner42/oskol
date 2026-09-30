/**
 * Captures the guest home, its sentence's menus (a friend, Sage), the friend
 * dialog, the sign-in, a lobby, the live games pill and its LIVE GAMES
 * dialog, and the theme picker at desktop and phone widths for visual
 * review. Run with the server up:
 *   node playwright/review-pages/test.js
 */
const playwright = require('playwright');
const { barItem, dismissResume, openHome, pickWord, createGame } = require('../lib/flows');
const OUT = process.argv[2] || 'playwright/screenshots/review-pages';
const fs = require('fs'); fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  const browser = await playwright.chromium.launch({ headless: true, executablePath: process.env.PW_CHROMIUM, args: ['--no-sandbox'] });
  for (const [name, vp] of [['desktop', { width: 1280, height: 900 }], ['phone', { width: 390, height: 844 }], ['narrow', { width: 320, height: 720 }]]) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
  // External fonts are blocked in sandboxes and would stall the load event.
  await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    const page = await ctx.newPage();
    await openHome(page); await page.waitForSelector('.lh-board .db-checker'); await sleep(1200);
    await page.screenshot({ path: `${OUT}/${name}-01-home.png` });
    // The sentence's menus: the game, open over the page.
    await page.click('#pick-game'); await page.waitForSelector('#pick-game-menu'); await sleep(400);
    await page.screenshot({ path: `${OUT}/${name}-02-sentence-game-menu.png` });
    await page.keyboard.press('Escape'); await page.waitForSelector('#pick-game-menu', { state: 'detached' });
    // Against a friend: the clock is a menu, the button says GET A LINK, and
    // pressing it asks the guest's name.
    await pickWord(page, 'who', 'pick-who-friend'); await sleep(400);
    await page.screenshot({ path: `${OUT}/${name}-02b-sentence-friend.png` });
    await page.click('#roll-dice'); await page.waitForSelector('#friend-modal #friend-name'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-02c-friend-dialog.png`, fullPage: true });
    await page.click('#close-friend');
    // Against Sage: no clock to pick, and PLAY NOW starts the game now.
    await pickWord(page, 'who', 'pick-who-bot'); await sleep(400);
    await page.screenshot({ path: `${OUT}/${name}-02d-sentence-sage.png` });
    // Sign in, from the bar (☰'s menu on a phone).
    await barItem(page, 'signin'); await page.waitForSelector('#signin-modal #signin-email'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-02e-signin.png` });
    await page.keyboard.press('Escape'); await sleep(300);
    // The lobby: create a backgammon game, which lands on /backgammon/<id>: a
    // seat is the guest who took it, so the URL carries no secret.
    await createGame(page, { name: 'Alice', mode: 'match5' }); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-03-backgammon-lobby.png`, fullPage: true });
    // Home again, now holding a seat: "1 live game" in the bar, and the
    // LIVE GAMES dialog behind it. Shoot both, then close it to get at the
    // picker.
    // On a phone the bar is the bird and ☰ (with a dot), and the pill is in
    // ☰'s menu: shoot the menu open too.
    await openHome(page); await page.waitForSelector('#resume-games', { state: 'attached' }); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-04a-home-with-games.png` });
    if (!(await page.isVisible('#resume-games'))) {
      await page.click('#nav-more'); await page.waitForSelector('#nav-menu'); await sleep(400);
      await page.screenshot({ path: `${OUT}/${name}-04b-nav-menu.png` });
      await page.keyboard.press('Escape'); await page.waitForSelector('#nav-menu', { state: 'detached' });
    }
    await barItem(page, 'live'); await page.waitForSelector('#resume-modal'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-04-live-games.png` });
    await dismissResume(page);
    // The theme picker, open on the home page.
    await barItem(page, 'themes'); await page.waitForSelector('#bg-theme-list'); await sleep(600);
    await page.screenshot({ path: `${OUT}/${name}-05-theme-picker.png` });
    await ctx.close();
  }
  await browser.close();
})();
