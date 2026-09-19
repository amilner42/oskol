/**
 * Accounts smoke: signing in by email, end to end, the mail read from the
 * dev endpoint (GET /dev/last-login) instead of a mailbox.
 *
 *  1. A creates a game, B joins it (two browsers, two guests).
 *  2. A goes home: LIVE GAMES opens with the offer, "Sign up".
 *     A types an email, gets "Check your email", types the six digits from
 *     the mail: the win, "1 game saved", CONTINUE.
 *  3. A opens the table: still seated (the seat is the account's now, and
 *     this browser is signed into it).
 *  4. A closes the table. C (a fresh browser) opens the invite: the seat
 *     belongs to an account and nothing is offered to claim.
 *  5. C signs in as the same account from that page, then opens the LINK
 *     from the mail. The page asks first: /papi/me is still a guest until
 *     the button is pressed (a GET signs nobody in). Pressed: the win.
 *  6. C's LIVE GAMES lists the room; C opens it and is seated.
 *  7. A logs out from the home bar's menu; A's table refuses it and sends
 *     it to the invite.
 *
 * Screenshots at 390x844, 320x640 and 844x390 of the offer, the code step,
 * the win and the owned invite.
 *
 * Run with the dev server up (/dev routes on):
 *   node playwright/test-accounts/test.js
 */
const playwright = require('playwright');
const fs = require('fs');
const { BASE, createGame, joinByLink, openSeat } = require('../lib/flows');

const SHOTS = 'playwright/screenshots/test-accounts';
const SIZES = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'small', width: 320, height: 640 },
  { name: 'landscape', width: 844, height: 390 },
];
const log = (m) => console.log(`[${new Date().toISOString().substr(11, 8)}] ${m}`);

/** The page at every size, then back to where it was. */
async function shots(page, label) {
  const before = page.viewportSize();
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    await page.waitForTimeout(150);
    await page.screenshot({ path: `${SHOTS}/${label}-${size.name}.png` });
    await noSideways(page, `${label} at ${size.width}x${size.height}`);
  }
  await page.setViewportSize(before);
}

/** Nothing on the page is wider than the screen. */
async function noSideways(page, what) {
  const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  if (wide > 1) throw new Error(`${what}: the page scrolls sideways by ${wide}px`);
}

/** The last sign-in the dev server mailed, once it is the one for `email` and not `seen`. */
async function mailFor(request, email, seen) {
  for (let i = 0; i < 50; i++) {
    const res = await request.get(`${BASE}/dev/last-login`);
    if (res.ok()) {
      const body = await res.json();
      if (body.email === email && body.link !== seen) return body;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`no sign-in mail for ${email}`);
}

async function me(page) {
  const res = await page.request.get(`${BASE}/papi/me`);
  return res.json();
}

async function run(browser, errors) {
  const contexts = [];
  const open = async (who) => {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
    await context.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
    contexts.push(context);
    const page = await context.newPage();
    page.on('pageerror', (e) => errors.push(`${who} pageerror: ${e.message}`));
    page.on('console', (m) => {
      if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`${who} console: ${m.text()}`);
    });
    return { context, page };
  };

  const email = `smoke+${Date.now().toString(36)}@oskol.test`;

  try {
    // 1. A game between two guests.
    const a = await open('A');
    const b = await open('B');
    const game = await createGame(a.page, { name: 'Alice' });
    await joinByLink(b.page, game.inviteUrl, 'Bob');
    await a.page.waitForSelector('.bg-board .checker');
    log(`game ${game.gameId}: Alice and Bob seated`);

    const flags = await me(a.page);
    if (flags.user !== null) throw new Error('a fresh guest is not signed in');

    // The table stays open in another tab of A's browser across the
    // sign-in: its socket is dropped with the old guest id and comes back
    // as the account, with no reload.
    const aTable = await a.context.newPage();
    aTable.on('pageerror', (e) => errors.push(`A table pageerror: ${e.message}`));
    await aTable.goto(game.url);
    await aTable.waitForSelector('.bg-board .checker');

    // 2. Home: LIVE GAMES, the offer, the email, the code, the win.
    await a.page.goto(`${BASE}/`);
    await a.page.waitForSelector('#resume-modal #resume-list');
    const offer = (await a.page.textContent('#signup-cta')).trim();
    if (offer !== 'Sign up') throw new Error(`the offer should say Sign up: "${offer}"`);
    await a.page.click('#signup-cta');
    await a.page.waitForSelector('#signin-email');
    await shots(a.page, '01-offer');
    await a.page.fill('#signin-email', email);
    await a.page.click('#signin-send');
    await a.page.waitForSelector('#signin-code');
    await shots(a.page, '02-code');
    const mail = await mailFor(a.page.request, email, null);
    if (!/^\d{6}$/.test(mail.code)) throw new Error(`the mail's code is six digits: "${mail.code}"`);
    // Typed as the mail prints it; the sixth digit submits.
    await a.page.fill('#signin-code', `${mail.code.slice(0, 3)} ${mail.code.slice(3)}`);
    await a.page.waitForSelector('#signin-win');
    const saved = (await a.page.textContent('#signin-saved')).trim();
    if (saved !== '1 game saved to your account.') throw new Error(`the win should count the game: "${saved}"`);
    // A new account is named after the name it played under (with a number
    // if another account has it), and never shows its email.
    const username = (await a.page.textContent('#username-name')).trim();
    if (!/^Alice\d*$/.test(username)) throw new Error(`the new account should be named after Alice: "${username}"`);
    await shots(a.page, '03-win');
    await a.page.click('#signin-continue');
    await a.page.waitForSelector('#signin-win', { state: 'detached' });
    if ((await a.page.$('#guest-note')) !== null) throw new Error('signed in, LIVE GAMES has no pitch');
    const bar = (await a.page.textContent('#account-button')).trim();
    if (!bar.includes(username)) throw new Error(`the bar should show the username: "${bar}"`);
    if (bar.includes('@')) throw new Error(`the bar must never show the email: "${bar}"`);
    log(`A signed in with the code: "${saved}"`);

    // The tab left at the table recovered on its own. Its old socket is
    // dropped shortly after the sign-in answers, so give the reconnect time
    // to happen before calling it steady.
    let steady = false;
    for (let i = 0; i < 60 && !steady; i++) {
      await aTable.waitForTimeout(250);
      const reconnecting = (await aTable.$('text=RECONNECTING')) !== null;
      const failed = (await aTable.$('#play-error')) !== null;
      steady = !reconnecting && !failed && (await aTable.$('.bg-board .checker')) !== null && i >= 16;
    }
    if (!steady) throw new Error('the table left open across the sign-in did not come back');
    if (aTable.url().includes('?game=')) throw new Error('the open table was sent to the invite by the sign-in');
    await aTable.close();
    log('the open table came back as the account, no reload');

    // 3. The table: still A's.
    await openSeat(a.page, game.url);
    await a.page.waitForSelector('.bg-board .checker');
    if (a.page.url().includes('?game=')) throw new Error('A was sent to the invite after signing in');
    log('A reopened the table and is seated');

    // 4. A away; a stranger with the invite finds the seat is an account's.
    await a.page.close();
    const c = await open('C');
    let owned = false;
    for (let i = 0; i < 30 && !owned; i++) {
      await c.page.goto(game.inviteUrl);
      await c.page.waitForSelector('#seat-owned, #reconnect, #table-full, #join-name');
      owned = (await c.page.$('#seat-owned')) !== null;
      if (!owned) await c.page.waitForTimeout(300);
    }
    if (!owned) throw new Error('the invite never said the seat belongs to an account');
    if ((await c.page.$$('[id^="reclaim-"]')).length) throw new Error('an owned seat must not be offered to claim');
    if (await c.page.$('#join-name')) throw new Error('an owned seat must not be offered by name');
    const says = await c.page.textContent('#seat-owned');
    if (!says.includes('This seat belongs to an account.')) throw new Error(`owned invite copy: "${says}"`);
    await shots(c.page, '04-owned-invite');
    log('C: the seat belongs to an account, nothing to claim');

    // 5. C signs in as the account from there, by the LINK.
    await c.page.fill('#signin-email', email);
    await c.page.click('#signin-send');
    await c.page.waitForSelector('#signin-code');
    const second = await mailFor(c.page.request, email, mail.link);
    await c.page.goto(second.link);
    await c.page.waitForSelector('#login-confirm');
    const before = await me(c.page);
    if (before.user !== null) throw new Error('opening the link signed the browser in: a GET must not');
    await c.page.click('#login-confirm');
    await c.page.waitForSelector('#signin-win');
    const after = await me(c.page);
    if (!after.user || after.user.email !== email) throw new Error(`after the button, /papi/me: ${JSON.stringify(after)}`);
    log('C: the link asked first, then signed in');

    // 6. C's LIVE GAMES has the room; it opens seated.
    await c.page.goto(`${BASE}/`);
    await c.page.waitForSelector(`#resume-${game.gameId}`);
    await c.page.click(`#resume-${game.gameId}`);
    await c.page.waitForSelector('.bg-board .checker');
    if (c.page.url().includes('?game=')) throw new Error('C was refused the account\'s seat');
    log('C: LIVE GAMES lists the room and C is seated');

    // 7. A logs out from the home bar; the table no longer opens for it.
    const a2 = await a.context.newPage();
    a2.on('pageerror', (e) => errors.push(`A2 pageerror: ${e.message}`));
    await a2.goto(`${BASE}/`);
    await a2.waitForSelector('#account-button');
    // The account's games open LIVE GAMES over the board once the list
    // arrives; close it first.
    await a2.waitForSelector('#resume-modal', { timeout: 10000 });
    await a2.click('#close-resume');
    await a2.waitForSelector('#resume-modal', { state: 'detached' });
    await a2.click('#account-button');
    await a2.click('#logout');
    // The bar is the guest's again: the guest mark, and SIGN IN behind the caret.
    await a2.waitForSelector('#account-button [data-identity="guest"]');
    const gone = await me(a2);
    if (gone.user !== null) throw new Error('logged out, /papi/me still names the account');
    await a2.goto(game.url);
    await a2.waitForURL(/\?game=/);
    log('A logged out and its table sent it to the invite; ACCOUNTS OK');
  } catch (e) {
    for (const context of contexts) {
      await Promise.all(
        context.pages().map((pg, i) => pg.screenshot({ path: `${SHOTS}/99-failure-${contexts.indexOf(context)}-${i}.png` }).catch(() => {}))
      );
    }
    throw e;
  } finally {
    for (const context of contexts) await context.close();
  }
}

async function main() {
  fs.mkdirSync(SHOTS, { recursive: true });
  const browser = await playwright.chromium.launch({
    headless: true,
    executablePath: process.env.PW_CHROMIUM || undefined,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  const errors = [];
  try {
    await run(browser, errors);
    if (errors.length) throw new Error('browser errors:\n' + errors.join('\n'));
  } catch (e) {
    console.error('ACCOUNTS SMOKE FAILED:', e.message);
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
}

main();
