/**
 * Card Draw Sort Test - Issue #61
 *
 * Tests that the 8-card initial draw is sorted by rank (descending) then by suit,
 * matching the in-game card sorting behavior.
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/screenshots/test-61-card-draw-sort';
const PORT = 4002; // Update this based on available port

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
  });

  const gameId = 'card-sort-test-' + Date.now();
  log(`Starting card sort test with game ID: ${gameId}`);

  try {
    // Create two browser contexts
    const context1 = await browser.newContext();
    const context2 = await browser.newContext();

    // ===== STEP 1: Create game with player 1 =====
    log('STEP 1: Player 1 creates game...');

    const page1 = await context1.newPage();
    await page1.goto(`http://localhost:${PORT}/`);
    await sleep(2000);

    // Fill name and create game
    await page1.fill('input[name="player_name"]', 'Player1');
    await sleep(300);
    await page1.click('button:has-text("New Game")');
    await sleep(2000);
    log('Player 1 created game');

    // Get the game URL
    const pageUrl = page1.url();
    const urlParams = new URL(pageUrl);
    const actualGameId = urlParams.searchParams.get('game');
    log(`Game ID: ${actualGameId}`);

    // ===== STEP 2: Player 2 joins =====
    log('STEP 2: Player 2 joins...');

    const page2 = await context2.newPage();
    await page2.goto(`http://localhost:${PORT}/?game=${actualGameId}`);
    await sleep(2000);

    await page2.fill('input[name="player_name"]', 'Player2');
    await sleep(300);
    await page2.click('button:has-text("Join Game")');
    await sleep(2000);
    log('Player 2 joined');

    // ===== STEP 3: Configure and start game =====
    log('STEP 3: Starting game...');

    // Both select Skirmish format (quick game)
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

    // ===== STEP 4: Screenshot initial card draw =====
    log('STEP 4: Capturing initial card draw to verify sorting...');

    await page1.screenshot({
      path: `${SCREENSHOT_DIR}/01-initial-draw-player1.png`,
      fullPage: true
    });
    await page2.screenshot({
      path: `${SCREENSHOT_DIR}/02-initial-draw-player2.png`,
      fullPage: true
    });
    log('Initial card draw captured');

    // ===== STEP 5: Try toggling sort to suit and back =====
    log('STEP 5: Testing sort toggle functionality...');

    // Toggle to suit sort
    const sortButton1 = await page1.$('button:has-text("Sorting by")');
    if (sortButton1) {
      await sortButton1.click();
      await sleep(1000);
      await page1.screenshot({
        path: `${SCREENSHOT_DIR}/03-suit-sort-player1.png`,
        fullPage: true
      });
      log('Toggled to suit sort');

      // Toggle back to rank sort
      await sortButton1.click();
      await sleep(1000);
      await page1.screenshot({
        path: `${SCREENSHOT_DIR}/04-rank-sort-player1.png`,
        fullPage: true
      });
      log('Toggled back to rank sort');
    }

    log('\n=== TEST COMPLETE ===');
    log(`Screenshots saved to ${SCREENSHOT_DIR}/`);
    log('VERIFICATION STEPS:');
    log('1. Check screenshots 01-02: Cards should be sorted by rank (high to low)');
    log('2. Cards of the same rank should be sorted by suit (spades, hearts, clubs, diamonds)');
    log('3. Screenshot 03: Cards should be sorted by suit');
    log('4. Screenshot 04: Cards should be back to rank sort');

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
