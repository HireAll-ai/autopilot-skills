#!/usr/bin/env bash
# After merge+deploy: re-run the acceptance e2e against production with
# guaranteed video recording (same deterministic Playwright machinery).
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true
source factory/hooks/lib-e2e.sh

: "${FACTORY_PROD_URL:?set FACTORY_PROD_URL per product}"

ARTIFACTS_DIR="factory-artifacts${FABRO_RUN_ID:+/$FABRO_RUN_ID}/prod"

ensure_playwright
ensure_e2e_specs
run_recorded_e2e "$FACTORY_PROD_URL" "$ARTIFACTS_DIR"

echo "=================================================="
echo "PROD E2E ARTIFACTS"
echo "Prod:     $FACTORY_PROD_URL"
echo
cat "$ARTIFACTS_DIR/VIDEOS.md" 2>/dev/null || { echo "Videos:"; print_video_list "$ARTIFACTS_DIR"; }
echo "=================================================="
