---
name: elixir-claude-code-web
description: Set up Elixir development in Claude Code Web with asdf and fix HEX SSL certificate issues. Use when working with Elixir/Phoenix projects in Claude Code Web environment. (project, gitignored)
---

# Elixir Setup for Claude Code Web

Get Elixir/Phoenix running in Claude Code Web environment.

## Install asdf

```bash
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
```

## Install Erlang & Elixir

```bash
. ~/.asdf/asdf.sh
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
asdf install  # reads from .tool-versions
mix local.hex --force
mix local.rebar --force
```

## CRITICAL: Fix HEX SSL Certificates

The proxy causes SSL errors. Always set this before any `mix` command:

```bash
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
```

## Install Dependencies & Run

```bash
. ~/.asdf/asdf.sh
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt

mix deps.get
mix compile
mix assets.setup  # Phoenix only
mix assets.build  # Phoenix only
mix phx.server    # Phoenix only
```

Server runs at http://localhost:4000

## One-Liner for Future Sessions

```bash
. ~/.asdf/asdf.sh && export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt && mix phx.server
```

## Common Error

**Error:** `TLS client: Unknown CA`
**Fix:** You forgot `export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt`
