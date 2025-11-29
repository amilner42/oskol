/**
 * Test for shop level-up multiplier display
 *
 * Verifies that when previewing a level-up card in the shop,
 * the multiplier shows the correct "current -> next" values.
 *
 * Bug #35: Previously showed "1x -> 1x" instead of "1x -> 2x"
 */

const playwright = require('playwright');

const PORT = process.env.PORT || 4001;
const BASE_URL = `http://localhost:${PORT}`;

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

  const context = await browser.newContext();

  log(`Starting test on ${BASE_URL}`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto(BASE_URL);
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/01-landing.png', fullPage: true });

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'TestPlayer1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/02-lobby-p1.png', fullPage: true });
    log('Player 1 created game and joined lobby');

    // Get the game URL
    const pageUrl = player1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins =====
    log('STEP 2: Player 2 joins game...');

    const player2 = await context.newPage();
    await player2.goto(`${BASE_URL}/?game=${actualGameId}`);
    await sleep(2000);

    await player2.fill('input[name="player_name"]', 'TestPlayer2');
    await sleep(300);
    await player2.click('button:has-text("Join Game")');
    await sleep(2000);
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/03-lobby-p2.png', fullPage: true });
    log('Player 2 joined lobby');

    // ===== STEP 3: Configure with 1HAND dev code =====
    log('STEP 3: Entering 1HAND dev code...');
    await player1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

    // Both select Skirmish format (has shop rounds)
    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/04-format-selected.png', fullPage: true });
    log('Both players selected Skirmish format');

    // ===== STEP 4: Start game =====
    log('STEP 4: Starting game...');
    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/05-game-started.png', fullPage: true });
    log('Game started');

    // ===== STEP 5: Play one hand =====
    log('STEP 5: Playing one hand...');

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

    // Skip hand results
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(1000);

    log('Hand complete');

    // ===== STEP 6: Wait for shop =====
    log('STEP 6: Waiting for shop...');
    await sleep(4000);

    // Skip any remaining dialogs
    const skipBtn1 = await player1.$('button:has-text("Skip")');
    if (skipBtn1) await skipBtn1.click();
    const skipBtn2 = await player2.$('button:has-text("Skip")');
    if (skipBtn2) await skipBtn2.click();
    await sleep(2000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/06-shop.png', fullPage: true });
    log('Shop screen reached');

    // ===== STEP 7: Find and click a level-up (Research) card =====
    log('STEP 7: Finding level-up card...');

    // The active picker should be able to click on cards
    const bodyText = await player1.textContent('body');
    const isP1Active = bodyText.includes('Your pick') || bodyText.includes('Your turn');
    const activePicker = isP1Active ? player1 : player2;
    const activePickerName = isP1Active ? 'Player1' : 'Player2';

    log(`Active picker: ${activePickerName}`);

    // Look for level-up/Research cards (they have "RESEARCH" type label)
    // These are in the Arsenal section (first 8 cards)
    await sleep(500);

    // Click on a preview_shop_card button to preview the card
    const shopCards = await activePicker.$$('[phx-click="preview_shop_card"]');
    log(`Found ${shopCards.length} clickable shop cards`);

    if (shopCards.length > 0) {
      // Click the first shop card (should be a level-up)
      await shopCards[0].click();
      await sleep(1500);

      // Take screenshot showing the level-up preview with multiplier values
      await activePicker.screenshot({
        path: 'playwright/screenshots/test-shop-mult-upgrade/07-level-up-preview.png',
        fullPage: true
      });
      log('Captured level-up preview');

      // Extract the multiplier text to verify fix
      const previewText = await activePicker.textContent('body');

      // Look for multiplier pattern - should show "1x" followed by arrow and "2x"
      if (previewText.includes('Multiplier')) {
        log('Found Multiplier section in preview');

        // Check if we can see the transition (e.g., "1x -> 2x")
        const multMatch = previewText.match(/(\d+)x[^0-9]*(\d+)x/);
        if (multMatch) {
          const [_, current, next] = multMatch;
          log(`Multiplier transition: ${current}x -> ${next}x`);

          if (parseInt(next) > parseInt(current)) {
            log('SUCCESS: Multiplier correctly shows increase!');
          } else {
            log('WARNING: Multiplier may not be showing correct increase');
          }
        }
      }
    }

    // ===== STEP 8: Try another level-up card for additional verification =====
    log('STEP 8: Testing another level-up card...');

    if (shopCards.length > 1) {
      await shopCards[1].click();
      await sleep(1500);

      await activePicker.screenshot({
        path: 'playwright/screenshots/test-shop-mult-upgrade/08-level-up-preview-2.png',
        fullPage: true
      });
      log('Captured second level-up preview');
    }

    log('\n=== TEST COMPLETE ===');
    log('Screenshots saved to playwright/screenshots/test-shop-mult-upgrade/');
    log('Verify screenshots show correct multiplier transitions (e.g., 1x -> 2x, not 1x -> 1x)');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-shop-mult-upgrade/ERROR.png', fullPage: true });
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
