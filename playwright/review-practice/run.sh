#!/usr/bin/env bash
# Serve this checkout on its own port and database, take the review-practice
# screenshots, and stop the server whatever happens.
#
#   playwright/review-practice/run.sh        (PORT=4475, OSKOL_DEV_DATABASE=oskol_practice_dev)
#
# The database is migrated first; `test.js` arranges everyone it shoots.
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4475}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_practice_dev}"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/review-practice-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$PORT/papi/practice/decks" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node playwright/review-practice/test.js "$@"
