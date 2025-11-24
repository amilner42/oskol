const { chromium } = require('playwright');

(async () => {
  console.log('Starting landing page screenshot...');

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  const page = await browser.newPage();
  await page.setViewportSize({ width: 1280, height: 720 });

  console.log('Navigating to landing page...');
  await page.goto('http://localhost:4000/');
  await page.waitForTimeout(2000);

  console.log('Taking screenshot...');
  await page.screenshot({
    path: 'playwright/screenshots/landing-page-before.png',
    fullPage: true
  });

  console.log('Screenshot saved to playwright/screenshots/landing-page-before.png');
  await browser.close();
})();
