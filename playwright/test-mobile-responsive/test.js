/**
 * Mobile Responsive Test - Game Screen
 *
 * Tests the mobile-friendly layout of the core game screen
 * Uses iPhone viewport (375x667) and takes screenshots at key game states
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/test-mobile-responsive/screenshots';

// Mobile viewport (iPhone SE)
const MOBILE_VIEWPORT = { width: 375, height: 667 };
// Tablet viewport (iPad Mini)
const TABLET_VIEWPORT = { width: 768, height: 1024 };
// Desktop viewport
const DESKTOP_VIEWPORT = { width: 1280, height: 720 };

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  const gameId = 'mobile-test-' + Date.now();
  log(`Starting mobile responsive test with game ID: ${gameId}`);

  try {
    // Create contexts with different viewports
    const mobileContext = await browser.newContext({ viewport: MOBILE_VIEWPORT });
    const desktopContext = await browser.newContext({ viewport: DESKTOP_VIEWPORT });

    // ===== STEP 1: Create game with mobile player =====
    log('STEP 1: Player 1 (mobile) creates game...');

    const mobilePage = await mobileContext.newPage();
    await mobilePage.goto('http://localhost:4000/');
    await sleep(2000);
    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/01-mobile-landing.png` });

    // Fill name and create game
    await mobilePage.fill('input[name="player_name"]', 'MobilePlayer');
    await sleep(300);
    await mobilePage.click('button:has-text("New Game")');
    await sleep(2000);
    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/02-mobile-lobby.png` });
    log('Mobile player created game');

    // Get the game URL
    const pageUrl = mobilePage.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Desktop player joins =====
    log('STEP 2: Player 2 (desktop) joins...');

    const desktopPage = await desktopContext.newPage();
    await desktopPage.goto(`http://localhost:4000/?game=${actualGameId}`);
    await sleep(2000);

    await desktopPage.fill('input[name="player_name"]', 'DesktopPlayer');
    await sleep(300);
    await desktopPage.click('button:has-text("Join Game")');
    await sleep(2000);
    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/03-desktop-lobby.png` });
    log('Desktop player joined');

    // ===== STEP 3: Enter 1HAND dev code and start =====
    log('STEP 3: Starting game...');

    // Enter dev code for quick test (1 hand per round)
    await mobilePage.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

    // Both select Skirmish format
    const skirmishBtn1 = await mobilePage.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await desktopPage.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    // Start game
    const startButton = await mobilePage.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }

    // ===== STEP 4: Screenshot game screen on both viewports =====
    log('STEP 4: Taking game screen screenshots...');

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/04-mobile-game-no-selection.png` });
    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/05-desktop-game-no-selection.png` });
    log('Initial game state captured');

    // ===== STEP 5: Select cards and capture =====
    log('STEP 5: Selecting cards...');

    // Mobile player selects 3 cards
    const mobileCards = await mobilePage.$$('button[phx-click="toggle_card"]');
    if (mobileCards.length >= 3) {
      await mobileCards[0].click();
      await sleep(200);
      await mobileCards[1].click();
      await sleep(200);
      await mobileCards[2].click();
      await sleep(500);
    }

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/06-mobile-cards-selected.png` });
    log('Mobile: 3 cards selected');

    // Desktop player selects 2 cards
    const desktopCards = await desktopPage.$$('button[phx-click="toggle_card"]');
    if (desktopCards.length >= 2) {
      await desktopCards[0].click();
      await sleep(200);
      await desktopCards[1].click();
      await sleep(500);
    }

    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/07-desktop-cards-selected.png` });
    log('Desktop: 2 cards selected');

    // ===== STEP 6: Play the hand =====
    log('STEP 6: Playing hands...');

    await mobilePage.click('button:has-text("Play")');
    await sleep(1000);
    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/08-mobile-waiting-opponent.png` });
    log('Mobile player locked in, waiting for opponent');

    await desktopPage.click('button:has-text("Play")');
    await sleep(2000);

    // ===== STEP 7: Capture hand results =====
    log('STEP 7: Capturing hand results...');

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/09-mobile-hand-results.png` });
    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/10-desktop-hand-results.png` });
    log('Hand results captured');

    // Skip to continue
    const mobileSkip = await mobilePage.$('button:has-text("Skip")');
    if (mobileSkip) await mobileSkip.click();
    const desktopSkip = await desktopPage.$('button:has-text("Skip")');
    if (desktopSkip) await desktopSkip.click();
    await sleep(2000);

    // ===== STEP 8: Capture shop screen =====
    log('STEP 8: Capturing shop screen...');

    // Wait for shop to appear and capture
    await sleep(2000);

    // Try to click skip if still on results
    const mobileSkip2 = await mobilePage.$('button:has-text("Skip")');
    if (mobileSkip2) await mobileSkip2.click();
    const desktopSkip2 = await desktopPage.$('button:has-text("Skip")');
    if (desktopSkip2) await desktopSkip2.click();
    await sleep(2000);

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/11-mobile-shop.png` });
    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/12-desktop-shop.png` });
    log('Shop screenshots captured');

    // ===== STEP 9: Open console panel on mobile =====
    log('STEP 9: Testing console panel on mobile...');

    // Go back to game by making shop picks quickly
    const mobileShopCards = await mobilePage.$$('[phx-click="preview_shop_card"]');
    if (mobileShopCards.length > 0) {
      await mobileShopCards[0].click();
      await sleep(500);
      const confirmBtn = await mobilePage.$('button:has-text("Confirm Selection")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1000);
    }

    const desktopShopCards = await desktopPage.$$('[phx-click="preview_shop_card"]');
    if (desktopShopCards.length > 0) {
      await desktopShopCards[0].click();
      await sleep(500);
      const confirmBtn = await desktopPage.$('button:has-text("Confirm Selection")');
      if (confirmBtn) await confirmBtn.click();
      await sleep(1000);
    }

    // Wait for next round
    await sleep(7000);

    // Now in round 2, open console
    const consoleBtn = await mobilePage.$('button[phx-click="toggle_console"]');
    if (consoleBtn) {
      await consoleBtn.click();
      await sleep(500);
    }

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/13-mobile-console-open.png` });
    log('Console panel on mobile captured');

    // Close console
    const closeBtn = await mobilePage.$('button[phx-click="toggle_console"]');
    if (closeBtn) await closeBtn.click();
    await sleep(300);

    // ===== STEP 10: Final comparison screenshots =====
    log('STEP 10: Final screenshots in round 2...');

    await mobilePage.screenshot({ path: `${SCREENSHOT_DIR}/14-mobile-round2.png` });
    await desktopPage.screenshot({ path: `${SCREENSHOT_DIR}/15-desktop-round2.png` });

    log('\n=== TEST COMPLETE ===');
    log(`Screenshots saved to ${SCREENSHOT_DIR}/`);
    log('Compare mobile vs desktop screenshots to verify responsive layout');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = [...(await browser.contexts()).flatMap(c => c.pages())];
      for (let i = 0; i < pages.length; i++) {
        await pages[i].screenshot({ path: `${SCREENSHOT_DIR}/ERROR-${i}.png` });
      }
      log('Error screenshots saved');
    } catch (e) {
      // Ignore screenshot errors
    }
  } finally {
    await browser.close();
    log('Browser closed');
  }
}

main().catch(console.error);
