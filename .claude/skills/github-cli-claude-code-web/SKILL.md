---
name: github-cli-claude-code-web
description: Set up GitHub CLI (gh) in Claude Code Web for PR creation, issue management, and repo operations. Use when working with GitHub from Claude Code Web. (project, gitignored)
---

# GitHub CLI Setup for Claude Code Web

Install and configure the GitHub CLI (`gh`) to work with your repositories.

## Setup

Run the setup script to install gh:

```bash
.claude/skills/github-cli-claude-code-web/setup.sh
```

**The script is idempotent** - it automatically skips steps that are already complete. You can safely run it whether this is a fresh instance or one that's already set up.

The script handles:
- GitHub CLI (`gh`) via direct binary download to `~/.local/bin`
- Configures authentication using existing GH_TOKEN

**IMPORTANT**: After setup, use the full path `$HOME/.local/bin/gh` for all commands. Each Bash invocation runs in a separate shell, so PATH changes don't persist between commands.

## Verify Setup

```bash
$HOME/.local/bin/gh auth status
```

## Common Commands

**Note**: In Claude Code Web, git remotes often point to a local proxy. You may need to add `--repo owner/repo` to commands that require repository context.

### Pull Requests
```bash
$HOME/.local/bin/gh pr create --title "Title" --body "Description" --repo owner/repo
$HOME/.local/bin/gh pr list --repo owner/repo
$HOME/.local/bin/gh pr view 123 --repo owner/repo
$HOME/.local/bin/gh pr checkout 123
$HOME/.local/bin/gh pr merge 123 --repo owner/repo
```

### Issues
```bash
$HOME/.local/bin/gh issue create --title "Title" --body "Description" --repo owner/repo
$HOME/.local/bin/gh issue list --repo owner/repo
$HOME/.local/bin/gh issue view 123 --repo owner/repo
$HOME/.local/bin/gh issue close 123 --repo owner/repo
```

### Repository
```bash
$HOME/.local/bin/gh repo view owner/repo
$HOME/.local/bin/gh repo clone owner/repo
```

## Troubleshooting

### Authentication failed
```bash
# Ensure GH_TOKEN is set
echo $GH_TOKEN
$HOME/.local/bin/gh auth status
```

### gh command not found
```bash
# Re-run setup
.claude/skills/github-cli-claude-code-web/setup.sh
```

### "none of the git remotes configured for this repository point to a known GitHub host"
This happens because Claude Code Web uses a local git proxy. Add `--repo owner/repo` to your commands:
```bash
$HOME/.local/bin/gh issue list --repo owner/repo
```
