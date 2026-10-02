#!/usr/bin/env bash
# Serve this checkout with the review tour's data, for walking the Analysis
# milestone by hand, until Ctrl-C:
#
#   playwright/review-analysis/serve.sh    (PORT=4487, OSKOL_DEV_DATABASE=oskol_dev_review_analysis)
#
# It arranges what setup.exs arranges (the seeded match at 821900, the
# universal sets, the account analysis-review@oskol.test; sign in as it from
# /dev/mailbox), starts the stand-in engine on PORT + 10000 so ANALYZE
# answers without a real one, and stops both when the server stops. The
# account's sets are kept: after run.sh it has "Openings I like".
set -euo pipefail
cd "$(dirname "$0")/../.."

export PORT="${PORT:-4487}"
export OSKOL_DEV_DATABASE="${OSKOL_DEV_DATABASE:-oskol_dev_review_analysis}"
export ANALYSIS_STUB_PORT="${ANALYSIS_STUB_PORT:-$((PORT + 10000))}"
export ANALYSIS_URL="http://localhost:$ANALYSIS_STUB_PORT"

mix ecto.create >/dev/null 2>&1 || true
mix ecto.migrate >/dev/null
mix assets.build >/dev/null
KEEP_SETS=1 mix run -e 'Code.eval_file("playwright/review-analysis/setup.exs")' | tail -1

# The stand-in serves until its input closes: a fifo this script holds open
# on fd 3, closed (and so the engine stopped) whenever this script ends.
fifo="$(mktemp -u "${TMPDIR:-/tmp}/review-analysis-engine.XXXXXX")"
mkfifo "$fifo"
mix run --no-start -e 'Code.eval_file("playwright/test-analysis/setup.exs")' <"$fifo" &
engine=$!
exec 3>"$fifo"
trap 'exec 3>&-; kill $engine 2>/dev/null || true; rm -f "$fifo"' EXIT

echo "http://localhost:$PORT/analysis  (the replay: /backgammon/821900/replay; sign in as analysis-review@oskol.test from /dev/mailbox)"
mix phx.server
