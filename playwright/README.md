# Playwright Tests

Automated browser tests for the Oskol poker roguelike game.

## Structure

```
playwright/
├── README.md                    # This file
├── screenshots/                 # Screenshots from test runs (COMMIT THESE!)
│   └── test-<name>/             # One folder per test
│       ├── 01-screenshot.png
│       └── 02-screenshot.png
└── test-<name>/                 # Test folder
    └── test.js                  # ONLY test.js - no README.md!
```

## Available Tests

### `test-tilt-smoke/`
Library → `/tilt` → lobby → start → both players play a hand. This is the test
that covers the current gamekit/protocol stack. The older `test-*` folders
predate the framework port and target the previous lobby URLs.

**Run:** `node playwright/test-tilt-smoke/test.js` (set `PW_CHROMIUM=/path/to/chrome` if the pinned browser is missing)

### `test-suit-action-card/`
End-to-end test covering lobby → game → shop flow, including the suit-changing card feature.

**Run:** `node playwright/test-suit-action-card/test.js`

## Running Tests

```bash
# Make sure server is running
mix phx.server

# Run a specific test (in another terminal)
node playwright/test-suit-action-card/test.js

# View screenshots
ls playwright/screenshots/test-suit-action-card/
```

## Screenshots

Screenshots are saved to `playwright/screenshots/<test-name>/`

## Adding New Tests

1. Create a new directory: `playwright/test-<name>/`
2. Add the test script: `playwright/test-<name>/test.js` (ONLY test.js - no README.md!)
3. Make sure screenshots save to: `playwright/screenshots/test-<name>/`
4. **IMPORTANT: Commit the screenshots!** They are used in PR documentation.

## Test Template

```javascript
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
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    log('Starting test...');

    await page.goto('http://localhost:4000');
    await sleep(1000);
    await page.screenshot({
      path: 'playwright/screenshots/my-test/01-homepage.png',
      fullPage: true
    });
    log('✓ Screenshot: 01-homepage.png');

    // Add your test steps here...

  } catch (error) {
    log(`ERROR: ${error.message}`);
    await page.screenshot({
      path: 'playwright/screenshots/my-test/ERROR.png',
      fullPage: true
    });
  } finally {
    await browser.close();
    log('Test complete!');
  }
}

main().catch(console.error);
```

## Best Practices

- **Use descriptive names** for tests and screenshots
- **Add timestamps** to logs for debugging
- **Save error screenshots** when tests fail
- **Use sleep() appropriately** - LiveView needs time to update
- **Keep tests focused** - one test per feature/flow
- **Commit screenshots** - they're used in PR documentation
- **No README.md in test folders** - only test.js is needed
