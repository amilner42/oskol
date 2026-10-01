#!/usr/bin/env bash
# Serve this checkout on its own port and database, take the review-decks
# screenshots, and stop the server whatever happens.
#
#   playwright/review-decks/run.sh        (PORT=4471, OSKOL_DEV_DATABASE=oskol_decks_dev)
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4471}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_decks_dev}"

mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/review-decks-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$PORT/papi/decks" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node playwright/review-decks/test.js
