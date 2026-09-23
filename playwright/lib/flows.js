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

// A seat's URL: /backgammon/<id>. Nothing in it says who you are -- a seat
// is held by the browser's guest cookie -- so one browser context is one
// player, and a second player needs a context of its own.
const SEAT = /\/backgammon\/([^/?#]+)/;

/**
 * `/` (or a game's own page) -> CREATE GAME -> the dialog, filled in by
 * nobody. For a smoke that wants to look at the dialog itself (what a name
 * is prefilled with, what the summary reads); a smoke that only wants a
 * game calls `createGame`.
 */
async function dismissResume(page) {
  await page.waitForSelector('#resume-modal');
  await page.click('#close-resume');
  await page.waitForSelector('#resume-modal', { state: 'detached' });
}

async function openCreateDialog(page, path = '/', { dismissResume: shouldDismissResume = false } = {}) {
  const gamesResponse = shouldDismissResume
    ? page.waitForResponse((response) => {
        const url = new URL(response.url());
        return response.request().method() === 'GET' && url.pathname === '/papi/me/games';
      })
    : null;

  // `/` is two pages -- the guest's board and an account's own home -- and
  // which one it is is settled only once /papi/me has answered, so wait for
  // that answer before reading the page. Set up before the visit: it may be
  // back before the first paint.
  const me = page.waitForResponse((response) => new URL(response.url()).pathname === '/papi/me');

  await page.goto(`${BASE}${path}`);
  await me;

  if (gamesResponse) {
    const games = await (await gamesResponse).json();
    if (games.games && games.games.length > 0) await dismissResume(page);
  }

  // CREATE GAME on the board, PLAY on an account's home. The dialog behind
  // them is the same one.
  await page.waitForSelector('#start-game, #home-play');
  const signedIn = (await page.$('#home-play')) !== null;
  await page.click(signedIn ? '#home-play' : '#start-game');
  // The dialog waits for the game's data, so wait for the dialog. Signed
  // in there is no name to type: the account plays under its username.
  await page.waitForSelector(signedIn ? '#create-modal #create-as' : '#create-modal #create-name');
}

/**
 * `/` -> CREATE GAME -> the dialog -> START GAME. `mode` and `clock` are
 * option values (`match3`, `bg3`); anything left out stays on the dialog's
 * default. Resolves once the creator is in the lobby with the link to
 * share.
 */
async function createGame(page, { name = 'Alice', mode, clock } = {}) {
  await openCreateDialog(page);
  if (await page.$('#create-name')) await page.fill('#create-name', name);
  if (mode) await page.selectOption('#create-mode', mode);
  if (clock) await page.selectOption('#create-clock', clock);
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

/** JOIN GAME on the home page: six characters, then the same invite. */
async function joinByCode(page, code, name = 'Bob') {
  await page.goto(`${BASE}/`);
  // JOIN GAME on the board, JOIN on an account's home: the same prompt.
  await page.waitForSelector('#join-game-board, #home-join');
  await page.click((await page.$('#home-join')) ? '#home-join' : '#join-game-board');
  await page.waitForSelector('#join-modal #join-code-input');
  // The sixth character submits on its own.
  await page.fill('#join-code-input', code);
  return takeSeat(page, name);
}

/**
 * A browser holding a seat: a context whose guest cookie is `guestId`, which
 * is what a seat is held by. Use one per player -- two pages in one context
 * are one browser, and one browser is one seat.
 */
function guestId() {
  return require('crypto').randomBytes(16).toString('base64url');
}

async function seatedContext(browser, guestId, options = {}) {
  const context = await browser.newContext(options);
  await context.addCookies([
    { name: '_oskol_guest', value: guestId, url: BASE, httpOnly: true, sameSite: 'Lax' },
  ]);
  return context;
}

/** A seat's own URL (the room's plain URL): the lobby or the board. */
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


/**
 * The result line of a setup script: the last line that is a JSON object.
 *
 * These scripts print their answer on stdout, and anything else on that
 * stream -- a query Ecto logged, a warning -- would be read as the answer
 * if we simply took the last line. They have all been quietened, but a
 * reader that says what it wants is better than one that hopes.
 */
function resultLine(out) {
  const line = out
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.startsWith('{') && l.endsWith('}'))
    .pop();
  if (!line) throw new Error(`no result line in setup output:\n${out.slice(-2000)}`);
  return line;
}

module.exports = { resultLine, BASE, dismissResume, openCreateDialog, createGame, joinByLink, joinByCode, openSeat, takeSeat, seatedContext, guestId };
