#!/usr/bin/env bash
# Serve this checkout on its own port and database, take the review-run
# screenshots (a run's strip, the refetch, the end card's way on, an early
# answer), and stop the server whatever happens.
#
#   playwright/review-run/run.sh        (PORT=4477, OSKOL_DEV_DATABASE=oskol_run_dev)
#
# The database is migrated first; `test.js` arranges everyone it shoots with
# review-practice's setup.exs and shape.exs (RUN_SETUP_FILE, a file holding the JSON line
# setup.exs printed, skips the arranging).
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4477}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_run_dev}"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/review-run-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$PORT/papi/practice/decks" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node playwright/review-run/test.js "$@"
