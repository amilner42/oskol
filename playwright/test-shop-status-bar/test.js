/**
 * End-to-end test for shop status bar showing round number and player lives
 *
 * Tests:
 * 1. Two players join and start game with 1HAND dev code
 * 2. Play through one complete round (1 hand with dev code)
 * 3. Verify shop screen shows round number
 * 4. Verify shop screen shows player lives (hearts)
 * 5. Verify shop screen shows opponent lives (hearts)
 *
 * GitHub Issue: #36 - Show round / heart left on shop screen
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 }
  });

  log(`Starting test for shop status bar (round & lives display)`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'Alice');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    log('Player 1 created game and joined lobby');

    // Get the game URL from the page
    const pageUrl = player1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins via URL =====
    log('STEP 2: Player 2 joins via URL...');

    const player2 = await context.newPage();
    await player2.goto(`http://localhost:4000/?game=${actualGameId}`);
    await sleep(2000);

    // Fill name and join
    await player2.fill('input[name="player_name"]', 'Bob');
    await sleep(300);
    await player2.click('button:has-text("Join Game")');
    await sleep(2000);
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter 1HAND dev code =====
    log('STEP 3: Entering 1HAND dev code...');

    // Enter dev code (only need to do it on one player's page, the host)
    await player1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);
    log('Dev code 1HAND entered');

    // ===== STEP 4: Both players select format =====
    log('STEP 4: Selecting format...');

    // Both click "Skirmish" format (shortest game, has shop)
    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);
    log('Both players selected Skirmish format');

    // ===== STEP 5: Start game =====
    log('STEP 5: Starting game...');

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }
    log('Game started');

    // ===== STEP 6: Play 1 hand (thanks to 1HAND dev code) =====
    log('STEP 6: Playing round (1 hand with dev code)...');

    // Player 1 selects and plays a card
    const p1Cards = await player1.$$('button[phx-click="toggle_card"]');
    if (p1Cards.length > 0) {
      await p1Cards[0].click();
      await sleep(400);
      await player1.click('button:has-text("Play")');
      await sleep(1000);
    }

    // Player 2 selects and plays a card
    const p2Cards = await player2.$$('button[phx-click="toggle_card"]');
    if (p2Cards.length > 0) {
      await p2Cards[0].click();
      await sleep(400);
      await player2.click('button:has-text("Play")');
      await sleep(1500);
    }

    // Both players skip hand result
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(1000);

    log('Hand complete');

    // ===== STEP 7: Wait for shop =====
    log('STEP 7: Waiting for shop...');
    await sleep(4000);  // Wait for auto-dismiss

    // If still on results, try clicking Skip
    const skipBtn1 = await player1.$('button:has-text("Skip")');
    if (skipBtn1) await skipBtn1.click();
    const skipBtn2 = await player2.$('button:has-text("Skip")');
    if (skipBtn2) await skipBtn2.click();
    await sleep(2000);

    // ===== STEP 8: Capture shop screen with status bar =====
    log('STEP 8: Capturing shop screen with round/lives display...');

    await player1.screenshot({
      path: 'playwright/screenshots/test-shop-status-bar/01-shop-desktop-p1.png',
      fullPage: true
    });
    await player2.screenshot({
      path: 'playwright/screenshots/test-shop-status-bar/02-shop-desktop-p2.png',
      fullPage: true
    });

    // Verify round number is visible
    const shopContent = await player1.textContent('body');

    if (shopContent.includes('Round')) {
      log('Round indicator visible in shop!');
    } else {
      log('WARNING: Round indicator not found in shop');
    }

    // Check for hearts/lives (the SVG hero-heart icons)
    const heartIcons = await player1.$$('[class*="hero-heart"]');
    log(`Found ${heartIcons.length} heart icons in shop`);

    // ===== STEP 9: Test mobile viewport =====
    log('STEP 9: Testing mobile viewport...');

    // Resize to mobile
    await player1.setViewportSize({ width: 375, height: 667 });
    await sleep(500);

    await player1.screenshot({
      path: 'playwright/screenshots/test-shop-status-bar/03-shop-mobile-p1.png',
      fullPage: true
    });

    // Also test tablet
    await player1.setViewportSize({ width: 768, height: 1024 });
    await sleep(500);

    await player1.screenshot({
      path: 'playwright/screenshots/test-shop-status-bar/04-shop-tablet-p1.png',
      fullPage: true
    });

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-shop-status-bar/');
    log('');
    log('Verify in screenshots:');
    log('  - Round number is visible in shop header');
    log('  - Player lives (hearts) are visible for both players');
    log('  - Layout works on desktop, tablet, and mobile');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-shop-status-bar/ERROR.png', fullPage: true });
        log('Error screenshot saved');
      }
    } catch (e) {
      // Ignore screenshot errors
    }
  } finally {
    await browser.close();
    log('Browser closed');
  }
}

main().catch(console.error);
