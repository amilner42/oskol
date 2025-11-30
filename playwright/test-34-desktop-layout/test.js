/**
 * Desktop Layout Test - Small Height Screen (MacBook Air)
 *
 * Tests that the game screen works properly on laptop screens
 * with limited height (like MacBook Air: 1440x900)
 * Ensures centerboard has enough space and point scores are visible
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/screenshots/test-34-desktop-layout';

// MacBook Air viewport (1440x900 scaled)
const MACBOOK_AIR_VIEWPORT = { width: 1440, height: 900 };

async function main() {
  const browser = await playwright.chromium.launch({
    headless: false,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
  });

  const gameId = 'desktop-layout-test-' + Date.now();
  log(`Starting desktop layout test with game ID: ${gameId}`);

  try {
    // Create contexts with MacBook Air viewport
    const context1 = await browser.newContext({ viewport: MACBOOK_AIR_VIEWPORT });
    const context2 = await browser.newContext({ viewport: MACBOOK_AIR_VIEWPORT });

    // ===== STEP 1: Create game with player 1 =====
    log('STEP 1: Player 1 creates game...');

    const page1 = await context1.newPage();
    await page1.goto('http://localhost:4000/');
    await sleep(2000);
    await page1.screenshot({ path: `${SCREENSHOT_DIR}/01-landing.png`, fullPage: true });

    // Fill name and create game
    await page1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await page1.click('button:has-text("New Game")');
    await sleep(2000);
    await page1.screenshot({ path: `${SCREENSHOT_DIR}/02-lobby-player1.png`, fullPage: true });
    log('Player 1 created game');

    // Get the game URL
    const pageUrl = page1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins =====
    log('STEP 2: Player 2 joins...');

    const page2 = await context2.newPage();
    await page2.goto(`http://localhost:4000/?game=${actualGameId}`);
    await sleep(2000);

    await page2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await page2.click('button:has-text("Join Game")');
    await sleep(2000);
    await page2.screenshot({ path: `${SCREENSHOT_DIR}/03-lobby-player2.png`, fullPage: true });
    log('Player 2 joined');

    // ===== STEP 3: Configure and start game =====
    log('STEP 3: Starting game...');

    // Enter dev code for quick test (1 hand per round)
    await page1.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

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

    // ===== STEP 4: Screenshot initial game state =====
    log('STEP 4: Capturing initial game state on MacBook Air viewport...');

    await page1.screenshot({ path: `${SCREENSHOT_DIR}/04-game-initial-player1.png`, fullPage: false });
    await page2.screenshot({ path: `${SCREENSHOT_DIR}/05-game-initial-player2.png`, fullPage: false });
    log('Initial game state captured - verify centerboard is visible');

    // ===== STEP 5: Select and play cards =====
    log('STEP 5: Playing hands to show score display...');

    // Player 1 selects 5 cards
    const cards1 = await page1.$$('button[phx-click="toggle_card"]');
    if (cards1.length >= 5) {
      for (let i = 0; i < 5; i++) {
        await cards1[i].click();
        await sleep(200);
      }
    }

    await page1.screenshot({ path: `${SCREENSHOT_DIR}/06-cards-selected-player1.png`, fullPage: false });
    log('Player 1: 5 cards selected');

    // Player 2 selects 5 cards
    const cards2 = await page2.$$('button[phx-click="toggle_card"]');
    if (cards2.length >= 5) {
      for (let i = 0; i < 5; i++) {
        await cards2[i].click();
        await sleep(200);
      }
    }

    await page2.screenshot({ path: `${SCREENSHOT_DIR}/07-cards-selected-player2.png`, fullPage: false });
    log('Player 2: 5 cards selected');

    // ===== STEP 6: Lock in hands =====
    log('STEP 6: Locking in hands...');

    await page1.click('button:has-text("Play")');
    await sleep(1000);
    await page1.screenshot({ path: `${SCREENSHOT_DIR}/08-waiting-player1.png`, fullPage: false });
    log('Player 1 locked in');

    await page2.click('button:has-text("Play")');
    await sleep(3000);

    // ===== STEP 7: Capture score display =====
    log('STEP 7: Capturing score display - KEY TEST FOR CENTERBOARD VISIBILITY...');

    // Wait a bit for animation to settle
    await sleep(2000);

    await page1.screenshot({ path: `${SCREENSHOT_DIR}/09-score-display-player1.png`, fullPage: false });
    await page2.screenshot({ path: `${SCREENSHOT_DIR}/10-score-display-player2.png`, fullPage: false });
    log('Score display captured - verify all scores are visible on screen');

    // ===== STEP 8: Skip and continue =====
    log('STEP 8: Continuing to round summary...');

    const skip1 = await page1.$('button:has-text("Skip")');
    if (skip1) await skip1.click();
    const skip2 = await page2.$('button:has-text("Skip")');
    if (skip2) await skip2.click();
    await sleep(3000);

    await page1.screenshot({ path: `${SCREENSHOT_DIR}/11-round-summary-player1.png`, fullPage: false });
    await page2.screenshot({ path: `${SCREENSHOT_DIR}/12-round-summary-player2.png`, fullPage: false });
    log('Round summary captured');

    log('\n=== TEST COMPLETE ===');
    log(`Screenshots saved to ${SCREENSHOT_DIR}/`);
    log('VERIFICATION STEPS:');
    log('1. Check screenshots 04-05: Centerboard should be visible with round info');
    log('2. Check screenshots 09-10: Score display should be fully visible without being cut off');
    log('3. Verify player cards are close to bottom, opponent cards close to top');
    log('4. Ensure no vertical scrolling is needed to see all game elements');

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
