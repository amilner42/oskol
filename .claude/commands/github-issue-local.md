# Complete a GitHub Issue (Local Development)

Complete a GitHub issue end-to-end using local development environment with git worktrees.

## Issue to work on: $ARGUMENTS

## Environment Setup

**IMPORTANT**: Before running any commands, source the environment file to get access to tools (mix, gh, node, etc.):

```bash
source ~/.claude/.claude-env
```

This file sets up PATH and environment variables (like GH_TOKEN) needed for local development. You must source this before every bash command since each invocation is a new shell.

## Workflow

### Step 1: Fetch Issue Details

```bash
source ~/.claude/.claude-env && gh issue view <issue-number> --repo amilner42/oskol
```

Read and understand the issue requirements before proceeding.

### Step 2: Start the Server

Find an available port and start the Phoenix server:

```bash
source ~/.claude/.claude-env && \
for port in 4001 4002 4003 4004 4005; do
  if ! lsof -i :$port > /dev/null 2>&1; then
    echo "Using port $port"
    export PORT=$port
    break
  fi
done && \
PORT=$PORT mix phx.server &
echo "Server running at http://localhost:$PORT"
```

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

### Step 5: Review Screenshots

Use the Read tool to view the captured screenshots and verify the implementation looks correct.

### Step 6: Commit and Create Pull Request

Once implementation is verified:

1. **Commit code changes AND screenshots together:**
   ```bash
   git add -A
   git add playwright/screenshots/test-<issue-slug>/
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

- This command is for local development (Elixir/gh already installed)
- Use port 4001+ to avoid conflicts with other instances
- Always commit screenshots with your changes
- Reference the issue number in commit messages and PR title
