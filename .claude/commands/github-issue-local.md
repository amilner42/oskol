# Complete a GitHub Issue (Local Development)

Complete a GitHub issue end-to-end using local development environment with git worktrees.

## Issue to work on: $ARGUMENTS

## CRITICAL: Do Not Install Anything

**All tools are already installed globally on this machine:**
- Elixir/Mix (via asdf)
- Node.js (via asdf)
- Playwright (global npm install)
- GitHub CLI (gh)

**NEVER run any of these commands:**
- `npm install` - breaks playwright browser version matching
- `npx playwright install` - browsers are already cached
- `brew install` - everything is already installed
- Any other package installation commands

If something is missing or not working, **STOP and ask the user** - do not try to install it yourself.

## Environment Setup

**IMPORTANT**: Before running any commands, source the environment file to get access to tools:

```bash
source ~/.claude/.claude-env
```

This file sets up PATH and environment variables (like GH_TOKEN) needed for local development. You must source this before every bash command since each invocation is a new shell.

## Workflow

### Step 1: Fetch Issue Details and Setup Dependencies

First, fetch the issue:

```bash
source ~/.claude/.claude-env && gh issue view <issue-number> --repo amilner42/oskol
```

Read and understand the issue requirements.

Then install Elixir dependencies (required for worktrees which don't share deps):

```bash
source ~/.claude/.claude-env && mix deps.get
```

### Step 2: Start the Server

Find an available port and start the Phoenix server. **Print the port clearly so the user can visit it:**

```bash
source ~/.claude/.claude-env && \
for port in 4001 4002 4003 4004 4005; do
  if ! lsof -i :$port > /dev/null 2>&1; then
    echo ""
    echo "========================================"
    echo "  SERVER STARTING ON PORT: $port"
    echo "  Visit: http://localhost:$port"
    echo "========================================"
    echo ""
    PORT=$port mix phx.server &
    break
  fi
done
```

**Note:** Remember which port was used - you'll need it for Playwright tests.

### Step 3: Implement the Issue

- Read the relevant code files to understand the current implementation
- Make the necessary changes to complete the issue
- Run `source ~/.claude/.claude-env && mix compile` to check for compilation errors
- Run `source ~/.claude/.claude-env && mix test` to ensure tests pass

### Step 4: Create Playwright Verification Script

After implementing the changes, create a Playwright test to visually verify the work:

1. Create a new test folder: `playwright/test-<issue-slug>/`
2. Add a `test.js` script that:
   - Navigates to the relevant screens (use the PORT from Step 2!)
   - Captures screenshots showing the changes
   - Saves to `playwright/screenshots/test-<issue-slug>/`

**IMPORTANT:**
- Only create `test.js` - do NOT create README.md files in test folders
- Use the correct port in the test: `http://localhost:${PORT}` (default 4001)
- Playwright is installed globally - just `require('playwright')` works

**Folder structure:**
```
playwright/
├── test-<issue-slug>/          # Test script ONLY
│   └── test.js                 # NO README.md here!
└── screenshots/
    └── test-<issue-slug>/      # Screenshots (same folder name!)
        ├── 01-screenshot.png
        └── 02-screenshot.png
```

Run the test:

```bash
source ~/.claude/.claude-env && node playwright/test-<issue-slug>/test.js
```

**If Playwright fails:** STOP and ask the user. Do NOT try to install browsers or packages.

### Step 5: Review Screenshots

Use the Read tool to view the captured screenshots and verify the implementation looks correct.

### Step 6: Commit and Create Pull Request

Once implementation is verified:

1. **Commit code changes AND screenshots together:**
   ```bash
   git add -A
   git add -f playwright/screenshots/test-<issue-slug>/   # -f needed because screenshots are gitignored
   git commit -m "Fix #<issue-number>: <description>"
   ```

   **CRITICAL: Make sure screenshots are committed!** Check with:
   ```bash
   git status  # Should show screenshots staged
   git diff --cached --name-only | grep screenshots  # Should list screenshot files
   ```

2. **Push and create PR:**
   ```bash
   source ~/.claude/.claude-env && git push -u origin HEAD

   source ~/.claude/.claude-env && gh pr create \
     --title "Fix #<issue-number>: <description>" \
     --body "## Summary
   <Brief description of changes>

   ## Screenshots
   ![Description](playwright/screenshots/test-<issue-slug>/01-screenshot.png)
   ![Description](playwright/screenshots/test-<issue-slug>/02-screenshot.png)

   Fixes #<issue-number>" \
     --repo amilner42/oskol
   ```

**IMPORTANT**: Always include screenshots in the PR body! They are committed to the repo and referenced with relative paths.

### Step 7: Summary

After completing all steps, provide:
- Summary of changes made
- List of files modified
- Screenshot review confirming the fix
- Link to the created PR
- Any notes or follow-up items

## Notes

- This command is for local development - everything is already installed
- Use port 4001+ to avoid conflicts with other instances
- Always commit screenshots with your changes
- Reference the issue number in commit messages and PR title
- **If something doesn't work, ask the user - don't try to fix it by installing packages**
