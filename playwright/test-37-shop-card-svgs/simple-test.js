const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const PORT = 4002;
const SCREENSHOT_DIR = 'playwright/screenshots/test-37-shop-card-svgs';

(async () => {
  // Clean screenshots directory before starting
  if (fs.existsSync(SCREENSHOT_DIR)) {
    fs.rmSync(SCREENSHOT_DIR, { recursive: true, force: true });
  }
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  const browser = await chromium.launch({ headless: false }); // Non-headless for manual interaction
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 }
  });
  const page = await context.newPage();

  try {
    console.log('Navigate to the game and manually get to the shop screen.');
    console.log('Once you are at the shop, press Enter in this terminal to take screenshots...');

    await page.goto(`http://localhost:${PORT}`);

    // Wait for user to press Enter
    await new Promise(resolve => {
      process.stdin.once('data', () => {
        resolve();
      });
    });

    console.log('Taking screenshots...');

    // Take full shop screenshot
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '01-shop-full.png'),
      fullPage: true
    });

    // Wait a bit and take desktop view
    await page.screenshot({
      path: path.join(SCREENSHOT_DIR, '02-shop-desktop.png'),
      fullPage: false
    });

    console.log('✅ Screenshots captured!');
    console.log('Browser will stay open. Close it when done.');

    // Keep browser open
    await new Promise(() => {});

  } catch (error) {
    console.error('❌ Error:', error);
  }
})();
