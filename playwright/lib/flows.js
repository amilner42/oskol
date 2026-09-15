/**
 * The ways into a game, once, for every smoke: create one from the home
 * page, join one by its invite link or by its code, open a seat's own URL.
 * Everything is driven by element ids, so a change to the home page or the
 * invite touches this file and nothing else.
 *
 *   const { createGame, joinByLink } = require('../lib/flows');
 *   const game = await createGame(p1, { name: 'Alice', mode: 'match3', clock: 'bg3' });
 *   await joinByLink(p2, game.inviteUrl, 'Bob');
 *
 * BASE_URL (or PORT) picks the server, as in every script here.
 */
const BASE = process.env.BASE_URL || `http://localhost:${process.env.PORT || 4400}`;

// A seat's URL: /backgammon/<id>?t=<token>
const SEAT = /\/backgammon\/([^/?#]+)/;

/**
 * `/` -> CREATE GAME -> the dialog -> START GAME. `mode`, `clock` and
 * `twist` are option values (`match3`, `bg3`, `pick_dice`); anything left
 * out stays on the dialog's default. Resolves once the creator is in the
 * lobby with the link to share.
 */
async function createGame(page, { name = 'Alice', mode, clock, twist } = {}) {
  await page.goto(`${BASE}/`);
  await page.click('#start-game');
  // The dialog waits for the game's data, so wait for the dialog.
  await page.waitForSelector('#create-modal #create-name');
  await page.fill('#create-name', name);
  if (mode) await page.selectOption('#create-mode', mode);
  if (clock) await page.selectOption('#create-clock', clock);
  if (twist) await page.selectOption('#create-setting-twist', twist);
  await page.click('#create-game');
  await page.waitForURL(SEAT);
  await page.waitForSelector('#share-link');
  const url = page.url();
  const gameId = url.match(SEAT)[1];
  const inviteUrl = (await page.textContent('#share-link')).trim();
  return { gameId, url, inviteUrl };
}

/** The invite link a friend was sent: a name, JOIN GAME, and the seat. */
async function joinByLink(page, inviteUrl, name = 'Bob') {
  await page.goto(inviteUrl);
  return takeSeat(page, name);
}

/** JOIN GAME on the home page: six digits, then the same invite. */
async function joinByCode(page, code, name = 'Bob') {
  await page.goto(`${BASE}/`);
  await page.click('#join-game-board');
  await page.waitForSelector('#join-modal #join-code-input');
  // The sixth digit submits on its own.
  await page.fill('#join-code-input', code);
  return takeSeat(page, name);
}

/** A seat's own URL (it carries the seat token): the lobby or the board. */
async function openSeat(page, url) {
  await page.goto(url);
  await page.waitForSelector('#share-link, .bg-board .checker');
  return { gameId: page.url().match(SEAT)[1], url: page.url() };
}

// Resolves with the seat and what the invite said the game was (`summary`,
// e.g. "Match to 3 · 3 min clock").
async function takeSeat(page, name) {
  await page.waitForSelector('#join-name');
  await page.waitForSelector('#setup-summary');
  const summary = (await page.textContent('#setup-summary')).trim();
  await page.fill('#join-name', name);
  await page.click('#join-game');
  await page.waitForURL(SEAT);
  return { gameId: page.url().match(SEAT)[1], url: page.url(), summary };
}

module.exports = { BASE, createGame, joinByLink, joinByCode, openSeat };
