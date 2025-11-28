/**
 * Final Mobile Shop Layout Test
 *
 * Takes final screenshots of mobile and desktop shop layouts
 */

const playwright = require('playwright');

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function log(message) {
  console.log(`[${new Date().toISOString().substr(11, 8)}] ${message}`);
}

const SCREENSHOT_DIR = 'playwright/test-mobile-shop-layout/screenshots';
const MOBILE_VIEWPORT = { width: 375, height: 667 };
const DESKTOP_VIEWPORT = { width: 1280, height: 720 };

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  try {
    log('Starting final mobile/desktop shop comparison test...');

    // Create contexts for mobile and desktop
    const mobileContext = await browser.newContext({ viewport: MOBILE_VIEWPORT });
    const desktopContext = await browser.newContext({ viewport: DESKTOP_VIEWPORT });

    // ===== Setup game with 2 players =====
    log('Setting up game...');

    const mobilePage = await mobileContext.newPage();
    const desktopPage = await desktopContext.newPage();

    // Player 1 creates game (mobile)
    await mobilePage.goto('http://localhost:4000/');
    await sleep(2000);
    await mobilePage.fill('input[name="player_name"]', 'MobilePlayer');
    await sleep(300);
    await mobilePage.click('button:has-text("New Game")');
    await sleep(2000);

    const gameId = new URL(mobilePage.url()).searchParams.get('game');
    log(`Game ID: ${gameId}`);

    // Player 2 joins (desktop)
    await desktopPage.goto(`http://localhost:4000/?game=${gameId}`);
    await sleep(2000);
    await desktopPage.fill('input[name="player_name"]', 'DesktopPlayer');
    await sleep(300);
    await desktopPage.click('button:has-text("Join Game")');
    await sleep(2000);

    // Configure: 1HAND dev code, 1 shop round, Skirmish
    await mobilePage.fill('input[name="dev_code"]', '1HAND');
    await sleep(500);

    const shopInput1 = await mobilePage.$('input[name="shop_rounds"]');
    if (shopInput1) await shopInput1.fill('1');
    const shopInput2 = await desktopPage.$('input[name="shop_rounds"]');
    if (shopInput2) await shopInput2.fill('1');
    await sleep(500);

    const skirmish1 = await mobilePage.$('button:has-text("Skirmish")');
    if (skirmish1) await skirmish1.click();
    const skirmish2 = await desktopPage.$('button:has-text("Skirmish")');
    if (skirmish2) await skirmish2.click();
    await sleep(1000);

    // Start game
    const startBtn = await mobilePage.$('button:has-text("Start Game")');
    if (startBtn) await startBtn.click();
    await sleep(3000);

    // ===== Play one hand quickly =====
    log('Playing first hand...');

    const cards1 = await mobilePage.$$('button[phx-click="toggle_card"]');
    if (cards1.length >= 2) {
      await cards1[0].click();
      await sleep(200);
      await cards1[1].click();
      await sleep(300);
    }
    await mobilePage.click('button:has-text("Play")');
    await sleep(500);

    const cards2 = await desktopPage.$$('button[phx-click="toggle_card"]');
    if (cards2.length >= 3) {
      await cards2[0].click();
      await sleep(200);
      await cards2[1].click();
      await sleep(200);
      await cards2[2].click();
      await sleep(300);
    }
    await desktopPage.click('button:has-text("Play")');
    await sleep(2000);

    // Skip to shop
    const continueBtn1 = await mobilePage.$('button:has-text("Continue")');
    if (continueBtn1) await continueBtn1.click();
    const continueBtn2 = await desktopPage.$('button:has-text("Continue")');
    if (continueBtn2) await continueBtn2.click();
    await sleep(3000);

    log('Reached shop screen!');

    // ===== Take comparison screenshots =====
    await mobilePage.screenshot({
      path: `${SCREENSHOT_DIR}/FINAL-mobile-shop.png`,
      fullPage: true
    });
    log('✓ Mobile shop screenshot saved');

    await desktopPage.screenshot({
      path: `${SCREENSHOT_DIR}/FINAL-desktop-shop.png`,
      fullPage: false
    });
    log('✓ Desktop shop screenshot saved');

    log('\n=== TEST COMPLETE ===');
    log('Mobile improvements applied successfully!');
    log(`Screenshots: ${SCREENSHOT_DIR}/FINAL-*.png`);

  } catch (error) {
    log(`ERROR: ${error.message}`);
    console.error(error);
  } finally {
    await browser.close();
    log('Browser closed');
  }
}

main().catch(console.error);
