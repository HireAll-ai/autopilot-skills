#!/usr/bin/env bash
# Acceptance e2e vs the preview deploy. Deterministic: Playwright runs the
# repo's e2e/ specs with video ALWAYS recorded (factory config); the agent's
# only role is authoring the specs. Fails on unmet criteria or missing video.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true
source factory/hooks/lib-e2e.sh

source factory-preview.env
: "${PREVIEW_URL:?preview-deploy.sh must run first}"

# Namespace artifacts per run when fabro provides the id (spec key decision 5).
ARTIFACTS_DIR="factory-artifacts${FABRO_RUN_ID:+/$FABRO_RUN_ID}/e2e"

ensure_playwright
ensure_e2e_specs
run_recorded_e2e "$PREVIEW_URL" "$ARTIFACTS_DIR"

# This output is what the operator sees at the acceptance gate.
echo "=================================================="
echo "ACCEPTANCE ARTIFACTS"
echo "Preview:  $PREVIEW_URL"
echo "Spec:     spec.md (design.html if UI); scenarios: e2e/"
echo
cat "$ARTIFACTS_DIR/VIDEOS.md" 2>/dev/null || { echo "Videos:"; print_video_list "$ARTIFACTS_DIR"; }
echo "=================================================="
