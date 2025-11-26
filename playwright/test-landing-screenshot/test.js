/**
 * Simple test to verify Playwright works by taking a screenshot of the landing page.
 */

const playwright = require('playwright');

async function main() {
  const browser = await playwright.chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });

  const page = await browser.newPage();

  console.log('Navigating to landing page...');
  await page.goto('http://localhost:4000');
  await new Promise(r => setTimeout(r, 2000));

  await page.screenshot({
    path: 'playwright/screenshots/test-landing-screenshot/landing.png',
    fullPage: true
  });
  console.log('Screenshot saved to playwright/screenshots/test-landing-screenshot/landing.png');

  await browser.close();
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
