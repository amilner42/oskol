#!/usr/bin/env bash
# Serve this checkout on its own port and database, run the analysis board's
# Playwright script (or the one named), and stop the server whatever happens.
#
#   playwright/test-analysis/run.sh            (PORT=4484, OSKOL_DEV_DATABASE=oskol_dev_analysis)
#   playwright/test-analysis/run.sh other.js   any script that reads BASE
#
# The server asks its engine at ANALYSIS_URL, here the stand-in the script
# starts (setup.exs) on ANALYSIS_STUB_PORT, PORT + 10000 unless named: an
# ANALYZE press never leaves this machine.
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4484}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_dev_analysis}"
export BASE="http://localhost:$PORT"
export ANALYSIS_STUB_PORT="${ANALYSIS_STUB_PORT:-$((PORT + 10000))}"
export ANALYSIS_URL="http://localhost:$ANALYSIS_STUB_PORT"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/test-analysis-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "$BASE/analysis" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node "${1:-playwright/test-analysis/test.js}" "${@:2}"
