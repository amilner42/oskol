#!/usr/bin/env bash
# Serve this checkout on its own port and database, take the review-verdict
# screenshots, and stop the server whatever happens.
#
#   playwright/review-verdict/run.sh      (PORT=4472, OSKOL_DEV_DATABASE=oskol_verdict_dev)
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4472}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_verdict_dev}"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
mix phx.server >"${TMPDIR:-/tmp}/review-verdict-server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null || true; wait $server 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$PORT/papi/library" >/dev/null 2>&1; then break; fi
  sleep 0.5
done

node playwright/review-verdict/test.js
