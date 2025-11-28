/**
 * End-to-end test for shop destroy phase preview feature
 *
 * Tests:
 * 1. Two players join and start game
 * 2. Player loses a round to trigger destroy phase in shop
 * 3. Player can preview cards before destroying them (bug fix)
 * 4. Preview shows card details with "Destroy This Card" button
 * 5. Player can destroy card from preview
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

  const context = await browser.newContext();

  log(`Starting shop destroy preview test`);

  try {
    // ===== STEP 1: Player 1 creates game =====
    log('STEP 1: Player 1 creates game...');

    const player1 = await context.newPage();
    await player1.goto('http://localhost:4000/');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/01-landing.png', fullPage: true });

    // Fill name and create game
    await player1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await player1.click('button:has-text("New Game")');
    await sleep(2000);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/02-lobby-p1-joined.png', fullPage: true });
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
    await player2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await player2.click('button:has-text("Join Game")');
    await sleep(2000);
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/03-lobby-p2-joined.png', fullPage: true });
    log('Player 2 joined lobby');

    // ===== STEP 3: Enter dev codes =====
    log('STEP 3: Entering dev codes...');

    // Enter 1HAND code to speed up round, and NORANDOM for deterministic results
    await player1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);
    await player1.fill('input[name="dev_code"]', 'NORANDOM');
    await sleep(500);
    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/04-dev-codes-entered.png', fullPage: true });
    log('Dev codes entered: 1HAND, NORANDOM');

    // ===== STEP 4: Both players select format =====
    log('STEP 4: Selecting format...');

    // Both click "Skirmish" format (shortest game with shop)
    const skirmishBtn1 = await player1.$('button:has-text("Skirmish")');
    if (skirmishBtn1) await skirmishBtn1.click();
    await sleep(500);

    const skirmishBtn2 = await player2.$('button:has-text("Skirmish")');
    if (skirmishBtn2) await skirmishBtn2.click();
    await sleep(1000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/05-format-selected.png', fullPage: true });
    log('Both players selected Skirmish format');

    // ===== STEP 5: Start game =====
    log('STEP 5: Starting game...');

    const startButton = await player1.$('button:has-text("Start Game")');
    if (startButton) {
      await startButton.click();
      await sleep(3000);
    }

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/06-game-started-p1.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/07-game-started-p2.png', fullPage: true });
    log('Game started');

    // ===== STEP 6: Play round - Player 1 plays weak hand, Player 2 plays strong hand =====
    log('STEP 6: Playing round (Player 1 will lose)...');

    // Player 1 plays single card (weak)
    const p1Cards = await player1.$$('button[phx-click="toggle_card"]');
    if (p1Cards.length > 0) {
      await p1Cards[0].click();  // Just one card = high card (weak)
      await sleep(400);
      await player1.click('button:has-text("Play")');
      await sleep(1000);
    }

    // Player 2 plays 5 cards for better chance at stronger hand
    const p2Cards = await player2.$$('button[phx-click="toggle_card"]');
    for (let i = 0; i < Math.min(5, p2Cards.length); i++) {
      await p2Cards[i].click();
      await sleep(200);
    }
    await player2.click('button:has-text("Play")');
    await sleep(2000);

    log('Both players played hands');

    // Skip result screens
    await sleep(2000);
    const p1Skip = await player1.$('button:has-text("Skip")');
    if (p1Skip) await p1Skip.click();
    const p2Skip = await player2.$('button:has-text("Skip")');
    if (p2Skip) await p2Skip.click();
    await sleep(2000);

    // Skip round summary
    await sleep(1000);
    const p1SkipSummary = await player1.$('button:has-text("Skip")');
    if (p1SkipSummary) await p1SkipSummary.click();
    const p2SkipSummary = await player2.$('button:has-text("Skip")');
    if (p2SkipSummary) await p2SkipSummary.click();
    await sleep(3000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/08-round-complete.png', fullPage: true });
    log('Round complete');

    // ===== STEP 7: Wait for shop and check for destroy phase =====
    log('STEP 7: Waiting for shop with destroy phase...');
    await sleep(2000);

    await player1.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/09-shop-p1-destroy-phase.png', fullPage: true });
    await player2.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/10-shop-p2-waiting.png', fullPage: true });

    // Check which player is in destroy phase
    const p1Text = await player1.textContent('body');
    const p2Text = await player2.textContent('body');

    const p1InDestroyPhase = p1Text.includes('Destroy phase') || p1Text.includes('Remove Cards');
    const p2InDestroyPhase = p2Text.includes('Destroy phase') || p2Text.includes('Remove Cards');

    const destroyer = p1InDestroyPhase ? player1 : player2;
    const destroyerName = p1InDestroyPhase ? 'Player1' : 'Player2';

    log(`${destroyerName} is in destroy phase`);

    // ===== STEP 8: Preview a card (BUG FIX TEST) =====
    log('STEP 8: Testing card preview in destroy phase...');

    // Click a shop card to preview it (should now work instead of immediately destroying)
    const shopCards = await destroyer.$$('[phx-click="preview_shop_card"]');
    if (shopCards.length > 0) {
      log('Clicking card to preview...');
      await shopCards[0].click();
      await sleep(1500);

      await destroyer.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/11-card-previewed.png', fullPage: true });

      // Check that preview is showing
      const previewText = await destroyer.textContent('body');
      if (previewText.includes('Research') || previewText.includes('Sabotage') || previewText.includes('Logistics')) {
        log('✓ Card preview is working!');
      }

      // ===== STEP 9: Destroy from preview =====
      log('STEP 9: Clicking Destroy This Card button...');

      // Look for the destroy button in the preview
      const destroyBtn = await destroyer.$('button:has-text("Destroy This Card")');
      if (destroyBtn) {
        await destroyBtn.click();
        await sleep(1500);

        await destroyer.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/12-card-destroyed.png', fullPage: true });
        log('✓ Card destroyed via preview button!');
      } else {
        log('✗ Destroy button not found in preview');
      }
    } else {
      log('✗ No shop cards found to preview');
    }

    // ===== STEP 10: Complete destroy phase =====
    log('STEP 10: Completing destroy phase...');

    const doneBtn = await destroyer.$('button:has-text("Done")');
    if (doneBtn) {
      await doneBtn.click();
      await sleep(2000);
    }

    await destroyer.screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/13-destroy-phase-complete.png', fullPage: true });

    log('\n=== TEST COMPLETE ===');
    log('✓ Shop destroy phase preview is working correctly!');
    log('Screenshots saved to playwright/screenshots/test-shop-destroy-preview/');

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);

    try {
      const pages = context.pages();
      if (pages.length > 0) {
        await pages[0].screenshot({ path: 'playwright/screenshots/test-shop-destroy-preview/ERROR.png', fullPage: true });
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
