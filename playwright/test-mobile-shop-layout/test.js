/**
 * Mobile Shop Layout Test
 *
 * Tests and captures mobile shop screen layout
 * Focus: Timeline height, card sizes, preview panel
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/test-mobile-shop-layout/screenshots';

// Mobile viewport (iPhone SE)
const MOBILE_VIEWPORT = { width: 375, height: 667 };

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  try {
    log('Starting mobile shop layout test...');

    // Create mobile context for both players
    const context = await browser.newContext({ viewport: MOBILE_VIEWPORT });

    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const page1 = await context.newPage();
    await page1.goto('http://localhost:4000/');
    await sleep(2000);

    await page1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await page1.click('button:has-text("New Game")');
    await sleep(2000);
    log('Player 1 created game');

    // Get the game URL
    const pageUrl = page1.url();
    const urlParams = new URL(pageUrl);
    const gameId = urlParams.searchParams.get('game');
    log(`Game ID: ${gameId}`);

    // ===== STEP 2: Player 2 joins =====
    log('STEP 2: Player 2 joins...');

    const page2 = await context.newPage();
    await page2.goto(`http://localhost:4000/?game=${gameId}`);
    await sleep(2000);

    await page2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await page2.click('button:has-text("Join Game")');
    await sleep(2000);
    log('Player 2 joined');

    // ===== STEP 3: Configure and start game (2 shop rounds, skirmish) =====
    log('STEP 3: Configuring game...');

    // Enter dev code for quick test (1 hand per round)
    await page1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

    // Set shop rounds to 2 on both sides
    const shopInput1 = await page1.$('input[name="shop_rounds"]');
    if (shopInput1) {
      await shopInput1.fill('2');
      await sleep(300);
    }

    const shopInput2 = await page2.$('input[name="shop_rounds"]');
    if (shopInput2) {
      await shopInput2.fill('2');
      await sleep(300);
    }

    // Both select Skirmish format
    const skirmishBtn1 = await page1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await page2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    // Start game
    const startButton = await page1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }
    log('Game started');

    // ===== STEP 4: Play one hand quickly =====
    log('STEP 4: Playing first hand...');

    // Player 1 selects and plays
    const cards1 = await page1.$$('button[phx-click="toggle_card"]');
    if (cards1.length >= 3) {
      await cards1[0].click();
      await sleep(200);
      await cards1[1].click();
      await sleep(200);
      await cards1[2].click();
      await sleep(300);
    }
    await page1.click('button:has-text("Play")');
    await sleep(500);

    // Player 2 selects and plays
    const cards2 = await page2.$$('button[phx-click="toggle_card"]');
    if (cards2.length >= 2) {
      await cards2[0].click();
      await sleep(200);
      await cards2[1].click();
      await sleep(300);
    }
    await page2.click('button:has-text("Play")');
    await sleep(2000);
    log('First hand completed');

    // Skip hand results
    const skip1 = await page1.$('button:has-text("Skip")');
    if (skip1) {
      await skip1.click();
      log('Clicked skip on page1');
    }
    const skip2 = await page2.$('button:has-text("Skip")');
    if (skip2) {
      await skip2.click();
      log('Clicked skip on page2');
    }
    await sleep(3000);

    // Check for round summary screen
    const roundSummarySkip = await page1.$('button:has-text("Continue")');
    if (roundSummarySkip) {
      await roundSummarySkip.click();
      log('Clicked Continue on round summary');
      await sleep(2000);
    }

    // ===== STEP 5: SHOP SCREEN - Initial state (no selection) =====
    log('STEP 5: Capturing shop initial state...');
    await sleep(3000); // Wait for shop to fully load

    // Check if we're actually on shop screen
    const shopCheck = await page1.textContent('body');
    if (shopCheck.includes('Command Center') || shopCheck.includes('Arsenal')) {
      log('Successfully reached shop screen!');
    } else {
      log('WARNING: May not be on shop screen yet');
      log('Current page content includes: ' + shopCheck.substring(0, 200));
    }

    await page1.screenshot({
      path: `${SCREENSHOT_DIR}/01-shop-no-selection.png`,
      fullPage: true
    });
    log('Screenshot 1: Shop with no card selected (full page)');

    // ===== STEP 6: SHOP - Card selected (level up card) =====
    log('STEP 6: Selecting a level-up card...');

    // Find and click a shop card to preview (prefer level up cards)
    const shopCards = await page1.$$('[phx-click="preview_shop_card"]');
    if (shopCards.length > 0) {
      await shopCards[0].click();
      await sleep(1000);
    }

    await page1.screenshot({
      path: `${SCREENSHOT_DIR}/02-shop-levelup-selected.png`,
      fullPage: true
    });
    log('Screenshot 2: Shop with level-up card selected (full page)');

    // ===== STEP 7: SHOP - Try deck builder card if available =====
    log('STEP 7: Trying to select deck builder card...');

    // Look for deck builder preview button
    const deckBuilderBtn = await page1.$('[phx-click="preview_deck_builder"]');
    if (deckBuilderBtn) {
      await deckBuilderBtn.click();
      await sleep(1000);

      await page1.screenshot({
        path: `${SCREENSHOT_DIR}/03-shop-deckbuilder-preview.png`,
        fullPage: true
      });
      log('Screenshot 3: Shop with deck builder card selected');

      // Click to choose cards
      const chooseBtn = await page1.$('button:has-text("Choose Cards")');
      if (chooseBtn) {
        await chooseBtn.click();
        await sleep(1000);

        await page1.screenshot({
          path: `${SCREENSHOT_DIR}/04-shop-deckbuilder-selection.png`,
          fullPage: true
        });
        log('Screenshot 4: Deck builder card selection screen');
      }
    } else {
      log('No deck builder card available, skipping screenshots 3-4');
    }

    // ===== STEP 8: Try action card (sabotage/denial) =====
    log('STEP 8: Trying to select action card...');

    // Look for plus bomb preview button
    const plusBombBtn = await page1.$('[phx-click="preview_plus_bomb"]');
    if (plusBombBtn) {
      await plusBombBtn.click();
      await sleep(1000);

      await page1.screenshot({
        path: `${SCREENSHOT_DIR}/05-shop-action-card.png`,
        fullPage: true
      });
      log('Screenshot 5: Shop with action card selected');
    }

    log('\n=== TEST COMPLETE ===');
    log(`Screenshots saved to ${SCREENSHOT_DIR}/`);
    log('Review screenshots to see current mobile shop layout');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = [...(await browser.contexts()).flatMap(c => c.pages())];
      for (let i = 0; i < pages.length; i++) {
        await pages[i].screenshot({
          path: `${SCREENSHOT_DIR}/ERROR-${i}.png`,
          fullPage: true
        });
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
