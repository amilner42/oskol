/**
 * Test for countered hand indication in Research tab (Issue #40)
 *
 * Simplified test that verifies the Research tab is accessible
 * and displays hand levels. Since Counter cards are random in shop,
 * this test focuses on verifying the UI is working.
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/screenshots/test-countered-hand-indication';

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  log('Starting countered hand indication test...');

  try {
    // Create context and page
    const context = await browser.newContext();
    const page = await context.newPage();

    // ===== STEP 1: Go to landing page =====
    log('STEP 1: Navigating to landing page...');
    await page.goto('http://localhost:4000/');
    await sleep(2000);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/01-landing.png`, fullPage: true });
    log('  Screenshot: 01-landing.png');

    // ===== STEP 2: Create a game =====
    log('STEP 2: Creating game...');
    await page.fill('input[name="player_name"]', 'TestPlayer');
    await sleep(300);
    await page.click('button:has-text("New Game")');
    await sleep(3000);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/02-lobby.png`, fullPage: true });
    log('  Screenshot: 02-lobby.png - In lobby');

    // Get game URL for another player
    const gameUrl = page.url();
    log(`  Game URL: ${gameUrl}`);

    // ===== STEP 3: Add second player with new page in same context =====
    log('STEP 3: Adding second player...');

    // Create a second page in the same context (more stable in headless)
    const page2 = await context.newPage();
    await page2.goto(gameUrl);
    await sleep(2000);

    await page2.fill('input[name="player_name"]', 'Opponent');
    await sleep(300);
    await page2.click('button:has-text("Join Game")');
    await sleep(2000);
    log('  Opponent joined');

    await page.screenshot({ path: `${SCREENSHOT_DIR}/03-both-in-lobby.png`, fullPage: true });

    // ===== STEP 4: Start game with 1HAND mode =====
    log('STEP 4: Starting game...');
    await page.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

    await page.click('button:has-text("Start Game")');
    await sleep(3000);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/04-game-started.png`, fullPage: true });
    log('  Game started');

    // ===== STEP 5: Both play a hand =====
    log('STEP 5: Playing hand...');

    // Player 1 plays
    const cards1 = await page.$$('button[phx-click="toggle_card"]');
    if (cards1.length > 0) {
      await cards1[0].click();
      await sleep(200);
      await page.click('button:has-text("Play")');
      await sleep(1000);
    }

    // Player 2 plays
    const cards2 = await page2.$$('button[phx-click="toggle_card"]');
    if (cards2.length > 0) {
      await cards2[0].click();
      await sleep(200);
      await page2.click('button:has-text("Play")');
      await sleep(1500);
    }

    // Skip hand result
    const skip1 = await page.$('button:has-text("Skip")');
    if (skip1) await skip1.click();
    const skip2 = await page2.$('button:has-text("Skip")');
    if (skip2) await skip2.click();
    await sleep(2000);

    // Skip round result
    const skipRound1 = await page.$('button:has-text("Skip")');
    if (skipRound1) await skipRound1.click();
    const skipRound2 = await page2.$('button:has-text("Skip")');
    if (skipRound2) await skipRound2.click();
    await sleep(2000);

    await page.screenshot({ path: `${SCREENSHOT_DIR}/05-after-round.png`, fullPage: true });
    log('  Round complete');

    // ===== STEP 6: Navigate shop if present =====
    log('STEP 6: Shop phase...');
    await sleep(2000);

    const bodyText = await page.textContent('body');
    if (bodyText.includes('Your turn') || bodyText.includes('First Pick')) {
      log('  In shop - looking for Counter cards...');

      // Look for Counter card
      const shopCards = await page.$$('[phx-click*="preview"]');
      let foundCounter = false;

      for (const card of shopCards) {
        const text = await card.textContent();
        if (text.includes('Counter')) {
          log('  Found Counter card!');
          foundCounter = true;
          await card.click();
          await sleep(1000);
          await page.screenshot({ path: `${SCREENSHOT_DIR}/06-counter-card.png`, fullPage: true });
          const confirm = await page.$('button:has-text("Confirm")');
          if (confirm) await confirm.click();
          await sleep(1500);
          break;
        }
      }

      if (!foundCounter) {
        log('  No Counter card, picking level up...');
        const levelCards = await page.$$('[phx-click="preview_shop_card"]');
        if (levelCards.length > 0) {
          await levelCards[0].click();
          await sleep(500);
          const confirm = await page.$('button:has-text("Confirm")');
          if (confirm) await confirm.click();
          await sleep(1000);
        }
      }

      // Opponent picks
      await sleep(1500);
      const oppCards = await page2.$$('[phx-click="preview_shop_card"]');
      if (oppCards.length > 0) {
        await oppCards[0].click();
        await sleep(500);
        const confirm = await page2.$('button:has-text("Confirm")');
        if (confirm) await confirm.click();
        await sleep(1000);
      }

      // Shop round 2
      await sleep(2000);
      const text2 = await page.textContent('body');
      if (text2.includes('Your turn')) {
        const cards = await page.$$('[phx-click="preview_shop_card"]');
        if (cards.length > 0) {
          await cards[0].click();
          await sleep(500);
          const confirm = await page.$('button:has-text("Confirm")');
          if (confirm) await confirm.click();
        }
      }

      await sleep(1500);
      const oppCards2 = await page2.$$('[phx-click="preview_shop_card"]');
      if (oppCards2.length > 0) {
        await oppCards2[0].click();
        await sleep(500);
        const confirm = await page2.$('button:has-text("Confirm")');
        if (confirm) await confirm.click();
      }

      // Ready up
      await sleep(2000);
      const ready1 = await page.$('button:has-text("Ready")');
      if (ready1) await ready1.click();
      const ready2 = await page2.$('button:has-text("Ready")');
      if (ready2) await ready2.click();
      await sleep(3000);
    }

    await page.screenshot({ path: `${SCREENSHOT_DIR}/07-round2.png`, fullPage: true });

    // ===== STEP 7: Open Research tab =====
    log('STEP 7: Opening Research tab...');

    // Click Research tab
    const researchBtn = await page.$('[phx-value-tab="levels"]');
    if (researchBtn) {
      await researchBtn.click();
      await sleep(1000);
    } else {
      // Try by text
      const btns = await page.$$('button');
      for (const btn of btns) {
        const text = await btn.textContent();
        if (text && text.includes('Research')) {
          await btn.click();
          await sleep(1000);
          break;
        }
      }
    }

    await page.screenshot({ path: `${SCREENSHOT_DIR}/08-research-tab-player1.png`, fullPage: true });
    log('  Screenshot: 08-research-tab-player1.png');

    // Check opponent's Research tab
    const oppResearch = await page2.$('[phx-value-tab="levels"]');
    if (oppResearch) {
      await oppResearch.click();
      await sleep(1000);
    }
    await page2.screenshot({ path: `${SCREENSHOT_DIR}/09-research-tab-player2.png`, fullPage: true });
    log('  Screenshot: 09-research-tab-player2.png');

    log('\n=== TEST COMPLETE ===');
    log(`Screenshots saved to ${SCREENSHOT_DIR}/`);
    log('Review screenshots to verify Research tab:');
    log('  - Shows all hand types with levels');
    log('  - If Counter card picked, opponent shows strikethrough');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error.stack);
  } finally {
    await browser.close();
    log('Browser closed');
  }
}

main().catch(console.error);
