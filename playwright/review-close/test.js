/**
 * Screenshots of the two ways a room that will not end itself is ended: the
 * ✕ on a LIVE GAMES row, END THIS GAME in the lobby, and END SESSION beside
 * READY between the games of unlimited play (plus the card a level session
 * ends on). Run with the server up:
 *   node playwright/review-close/test.js
 */
const playwright = require('playwright');
const { barItem, openHome, createGame, joinByLink } = require('../lib/flows');
const OUT = process.argv[2] || 'playwright/screenshots/review-close';
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
    // Two players are two browsers: a seat is held by the guest cookie.
    const alice = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
    const bob = await browser.newContext({ viewport: vp, deviceScaleFactor: 1 });
    for (const ctx of [alice, bob]) {
      await ctx.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    }
    const a = await alice.newPage();
    const b = await bob.newPage();

    // The lobby nobody has joined: END THIS GAME under the invite.
    const game = await createGame(a, { name: 'Alice', mode: 'unlimited' });
    await a.waitForSelector('#close-lobby');
    await sleep(600);
    await a.screenshot({ path: `${OUT}/${name}-01-lobby.png`, fullPage: true });

    // The same room from the home page's "1 live game" in ☰: the row is the
    // link, the ✕ beside it.
    await openHome(a);
    await a.waitForSelector('#nav-more .lh-burger-dot');
    await barItem(a, 'live');
    await a.waitForSelector('#resume-modal #close-' + game.gameId);
    await sleep(600);
    await a.screenshot({ path: `${OUT}/${name}-02-live-games.png` });
    await a.hover(`#close-${game.gameId}`);
    await sleep(300);
    await a.screenshot({ path: `${OUT}/${name}-03-live-games-hover.png` });

    // Bob joins and the game starts. End it quickly with a resignation, so
    // the shot is of the pause and not of a game played out.
    await a.goto(game.url);
    await joinByLink(b, game.inviteUrl, 'Bob');
    await a.waitForSelector('#bg-resign-open');
    await a.click('#bg-resign-open');
    await a.waitForSelector('#bg-resign-single');
    await a.click('#bg-resign-single');
    await b.waitForSelector('#bg-action-accept_resign');
    await b.click('#bg-action-accept_resign');

    // Between games of unlimited play: READY, and END SESSION beside it.
    await a.waitForSelector('#bg-action-close');
    await sleep(900);
    await a.screenshot({ path: `${OUT}/${name}-04-between-games.png` });

    // A level session: one each, then the card it ends on.
    await a.click('#bg-action-ready');
    await b.waitForSelector('#bg-action-ready');
    await b.click('#bg-action-ready');
    await b.waitForSelector('#bg-resign-open');
    await b.click('#bg-resign-open');
    await b.waitForSelector('#bg-resign-single');
    await b.click('#bg-resign-single');
    await a.waitForSelector('#bg-action-accept_resign');
    await a.click('#bg-action-accept_resign');
    await a.waitForSelector('#bg-action-close');
    await a.click('#bg-action-close');
    await a.waitForSelector('#bg-replay');
    await sleep(900);
    await a.screenshot({ path: `${OUT}/${name}-05-session-over.png` });

    await alice.close();
    await bob.close();
  }

  await browser.close();
})();
