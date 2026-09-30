/**
 * The ways into a game, once, for every smoke: create one from the home
 * page, join one by its invite link or by its code, open a seat's own URL.
 * Everything is driven by element ids, so a change to the home page or the
 * invite touches this file and nothing else.
 *
 *   const { createGame, joinByLink } = require('../lib/flows');
 *   const game = await createGame(p1, { name: 'Alice', mode: 'match3', clock: 'bg3' });
 *   (a guest says it in the home page's sentence; an account uses PLAY's dialog)
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
 * The list of live games, if it is open. The guest home no longer opens it by
 * itself (the bar's "N live games" does), so this only closes one a smoke
 * opened; it is kept for the scripts that call it.
 */
async function dismissResume(page) {
  if (!(await page.$('#resume-modal'))) return;
  await page.click('#close-resume');
  await page.waitForSelector('#resume-modal', { state: 'detached' });
}

/**
 * Visit `path` and wait until `/` has settled which home it is: the guest's
 * (the sentence and ROLL DICE) or an account's (PLAY). `/papi/me` decides,
 * so wait for its answer, set up before the visit since it may come back
 * before the first paint.
 */
async function openHome(page, path = '/') {
  const me = page.waitForResponse((response) => new URL(response.url()).pathname === '/papi/me');
  await page.goto(`${BASE}${path}`);
  await me;
  await page.waitForSelector('#roll-dice, #home-play');
  return (await page.$('#home-play')) !== null ? 'account' : 'guest';
}

/**
 * An account's home -> PLAY -> CREATE GAME's dialog, filled in by nobody.
 * Only the signed-in home has the dialog; the guest home is the sentence.
 */
async function openCreateDialog(page, path = '/') {
  const home = await openHome(page, path);
  if (home !== 'account') throw new Error('openCreateDialog: the guest home has no dialog; use createGame');
  await page.click('#home-play');
  await page.waitForSelector('#create-modal #create-as');
}

/**
 * One word of the guest home's sentence: open its menu, pick the option.
 * The options exist once the game's data has come, so wait for the one.
 */
async function pickWord(page, word, optionId) {
  await page.click(`#pick-${word}`);
  await page.waitForSelector(`#pick-${word}-menu #${optionId}`);
  await page.click(`#${optionId}`);
  await page.waitForSelector(`#pick-${word}-menu`, { state: 'detached' });
}

/**
 * A new game from `/`. `mode` and `clock` are the game's ids (`match3`,
 * `bg3`); anything left out stays on the default (a single game, no clock).
 * A guest says it in the sentence -- "Play [a match to 3] against [a friend]
 * with [a 3 min clock]" -- and presses GET A LINK, which asks the friend's
 * name for them; an account uses PLAY's dialog, as before. Resolves once the
 * creator is in the lobby with the link to share.
 *
 * `opponent: 'bot'` picks Sage instead: the table fills itself, so there is
 * no link and no lobby -- it resolves on the board, and `inviteUrl` is null.
 * A guest plays Sage under the name the browser last played under, or
 * "Guest": there is no name to type.
 */
async function createGame(page, { name = 'Alice', mode, clock, opponent } = {}) {
  const home = await openHome(page);
  const bot = opponent === 'bot';
  if (home === 'account') {
    await page.click('#home-play');
    await page.waitForSelector('#create-modal #create-as');
    if (bot) await page.click('#create-opponent-bot');
    if (mode) await page.selectOption('#create-mode', mode);
    if (clock && !bot) await page.selectOption('#create-clock', clock);
    await page.click('#create-game');
  } else {
    if (bot) {
      if ((await page.textContent('#pick-who')).trim() !== 'Sage') await pickWord(page, 'who', 'pick-who-bot');
    } else {
      await pickWord(page, 'who', 'pick-who-friend');
    }
    if (mode) await pickWord(page, 'game', `pick-game-${mode}`);
    if (clock && !bot) await pickWord(page, 'clock', `pick-clock-${clock}`);
    await page.click('#roll-dice');
    if (!bot) {
      await page.waitForSelector('#friend-modal #friend-name');
      await page.fill('#friend-name', name);
      await page.click('#friend-go');
    }
  }
  await page.waitForURL(SEAT);
  await page.waitForSelector(bot ? '.bg-board .checker' : '#share-link');
  const url = page.url();
  const gameId = url.match(SEAT)[1];
  const inviteUrl = bot ? null : (await page.textContent('#share-link')).trim();
  return { gameId, url, inviteUrl };
}

/** The invite link a friend was sent: a name, JOIN GAME, and the seat. */
async function joinByLink(page, inviteUrl, name = 'Bob') {
  await page.goto(inviteUrl);
  return takeSeat(page, name);
}

/**
 * JOIN on the home page: six characters, then the same invite. The guest
 * home's bar has the code field itself on a wide screen (the sixth
 * character goes on its own); a phone, and an account's home, have a JOIN
 * button that opens the prompt.
 */
async function joinByCode(page, code, name = 'Bob') {
  await openHome(page);
  if (await page.isVisible('#nav-join-code')) {
    await page.fill('#nav-join-code', code);
  } else {
    await page.click('#home-join');
    await page.waitForSelector('#join-modal #join-code-input');
    // The sixth character submits on its own.
    await page.fill('#join-code-input', code);
  }
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

module.exports = { resultLine, BASE, dismissResume, openHome, openCreateDialog, pickWord, createGame, joinByLink, joinByCode, openSeat, takeSeat, seatedContext, guestId };
