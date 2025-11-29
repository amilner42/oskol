---
name: elixir-claude-code-web
description: Set up Elixir/Phoenix development in Claude Code Web with asdf, npm, and Playwright. Use when working with Elixir/Phoenix projects in Claude Code Web environment. (project, gitignored)
---

# Elixir Setup for Claude Code Web

Complete setup for Elixir/Phoenix development with testing tools.

## Setup

Run the setup script to prepare the environment:

```bash
.claude/skills/elixir-claude-code-web/setup.sh
```

**The script is idempotent** - it automatically skips steps that are already complete. You can safely run it whether this is a fresh instance or one that's already set up.

The script handles:
- asdf version manager
- Erlang & Elixir (from .tool-versions)
- Hex and Rebar
- Project dependencies
- Phoenix assets
- Playwright for testing

After setup, the server runs at http://localhost:4000

## Running Tests

```bash
mix test
```

## Running Playwright Tests

```bash
# Start server in background
mix phx.server &

# Run playwright test
node playwright/<test-folder>/test.js
```

## Troubleshooting

### SSL/TLS Unknown CA errors
```bash
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
```

### asdf not found
```bash
. ~/.asdf/asdf.sh
```

### mix/elixir not found after asdf install
```bash
asdf reshim elixir
```

### Playwright browser not found
```bash
npx playwright install chromium
```

### Dependencies out of date
```bash
mix deps.get
mix compile
```
