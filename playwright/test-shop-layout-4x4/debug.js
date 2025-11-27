const { chromium } = require('playwright');

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
  });
  const page = await browser.newPage();

  try {
    console.log('Loading landing page...');
    await page.goto('http://localhost:4000');
    await sleep(3000);

    // Take a screenshot to see what's on the page
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/debug-landing.png', fullPage: true });
    console.log('Screenshot saved: debug-landing.png');

    // Get the page text
    const bodyText = await page.textContent('body');
    console.log('Page text (first 500 chars):');
    console.log(bodyText.substring(0, 500));

    // Count buttons
    const buttons = await page.$$('button');
    console.log(`\nFound ${buttons.length} buttons on the page`);

    // Try to find input fields
    const inputs = await page.$$('input');
    console.log(`Found ${inputs.length} input fields`);

    console.log('\n✅ Debug complete!');

  } catch (error) {
    console.error('❌ Debug failed:', error);
    await page.screenshot({ path: 'playwright/test-shop-layout-4x4/debug-error.png', fullPage: true });
  } finally {
    await browser.close();
  }
})();
