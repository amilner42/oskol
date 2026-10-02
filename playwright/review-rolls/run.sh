#!/usr/bin/env bash
# Build the stylesheet, then take the ROLLS review screenshots:
#
#   playwright/review-rolls/run.sh
#
# No server, no database and no engine: the component is pure and has no page
# yet, so test.js compiles Harness.elm and serves it with the real built
# app.css and the real fonts out of priv/static on its own port
# (ROLLS_HARNESS_PORT, 4489 by default). Nothing is touched on 4400.
set -euo pipefail
cd "$(dirname "$0")/../.."

mix assets.build >/dev/null
node playwright/review-rolls/test.js "$@"
