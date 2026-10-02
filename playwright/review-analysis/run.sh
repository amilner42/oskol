#!/usr/bin/env bash
# Serve this checkout on its own port and database, take the Analysis
# milestone's review screenshots, and stop the server whatever happens.
#
#   playwright/review-analysis/run.sh    (PORT=4487, OSKOL_DEV_DATABASE=oskol_dev_review_analysis)
#
# The server asks its engine at ANALYSIS_URL, the stand-in `test.js` starts
# on ANALYSIS_STUB_PORT (PORT + 10000 unless named): no press leaves this
# machine. `test.js` arranges everything it shoots (setup.exs).
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4487}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_dev_review_analysis}"
export BASE="http://localhost:$PORT"
export ANALYSIS_STUB_PORT="${ANALYSIS_STUB_PORT:-$((PORT + 10000))}"
export ANALYSIS_URL="http://localhost:$ANALYSIS_STUB_PORT"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/review-analysis-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "$BASE/analysis" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node playwright/review-analysis/test.js "$@"
