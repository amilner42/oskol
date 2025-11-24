---
name: playwright-testing-claude-code-web
description: Use Playwright MCP for UI testing in Claude Code, capturing screenshots to confirm key behavior. Use when testing web UIs. (project, gitignored)
---

# Playwright Testing in Claude Code Web

Navigate and test UIs with Playwright in headless environment. User can't access localhost, so Claude explores the app
and saves screenshots.

## Playwright Config (One-time setup)

Create `playwright.config.js` if it doesn't exist:

```javascript
module.exports = {
  use: {
    headless: true,
    launchOptions: {
      args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--single-process']
    }
  }
};
```

## Recommended Approach: Direct Node.js Script

For complex interactive flows (multiple pages, forms, waiting for state changes), use a **Node.js script** instead of Playwright test runner.

### Example: Full Game Flow Test

See `playwright/test-suit-action-card/` in this project for a real-world example that:
- Opens 2 browser contexts (2 players)
- Navigates through lobby, game, and shop screens
- Uses proper selectors (phx-click, input[name])
- Captures 14+ screenshots at key moments
- Handles LiveView state updates with appropriate waits
- Organized with test script + README in its own folder

**To create a new test**, see the template in `playwright/README.md` or copy an existing test folder.

## Key Points

- **Node.js scripts work better** than test runner for complex flows with LiveView/WebSockets
- **Save screenshots to `playwright/screenshots/<test-name>/`
- **Use `page.$$()` for multi-element queries** instead of `.waitForSelector()` loops
- **Add logging** with timestamps to track test progress
- **Handle errors gracefully** with try/catch and error screenshots
- **Inspect HTML carefully** - use Grep to find actual phx-click handlers and form names
- **No xvfb-run needed** - headless Chromium works without it
- **No package.json needed** - use `npx -y playwright` or direct require('playwright')
- **Read screenshots with Read tool** to verify what was captured

## Troubleshooting Tips

### Finding the right selectors
```bash
# Search for phx-click handlers
grep -r "phx-click" lib/your_app_web/components/

# Search for form field names
grep -r "name=" lib/your_app_web/components/
```

### Common issues
- **Elements not found**: LiveView may still be loading. Add `await sleep(2000)` after navigation
- **Timeouts on button clicks**: Check if button text matches exactly (case-sensitive)
- **Form submissions fail**: Use `page.fill('input[name="field"]')` not `input[placeholder="text"]`
- **Multi-page navigation**: Open new pages with `context.newPage()` for simultaneous users
- **State not updating**: LiveView needs time after actions. Increase sleep() durations

### Debugging
```javascript
// See what text is on the page
const bodyText = await page.textContent('body');
console.log(bodyText.substring(0, 500));

// Count elements
const buttons = await page.$$('button');
console.log(`Found ${buttons.length} buttons`);

// Take debug screenshot
await page.screenshot({ path: 'debug.png', fullPage: true });
```

## Project Organization

**Recommended structure:**
```
project/
├── playwright/
│   ├── README.md                  # Overview of all tests
│   ├── screenshots/               # Test output
│   │   └── test-suit-action-card/            # One folder per test
│   └── test-suit-action-card/                 # Example test
│       ├── README.md             # What this test does
│       └── test.js               # The test script
```

**Benefits:**
- Each test has its own folder with documentation
- Screenshots organized by test name
- Easy to add new tests without cluttering root
- Clear structure for multiple test suites
- Can reference tests in skills/documentation

## Running Tests

```bash
# Start server
mix phx.server

# Run a test (in another terminal)
node playwright/test-suit-action-card/test.js

# View screenshots
ls -lh playwright/screenshots/test-suit-action-card/
```

## Adding New Tests

See `playwright/README.md` for:
- How to structure a new test
- Test template with logging and error handling
- Best practices
