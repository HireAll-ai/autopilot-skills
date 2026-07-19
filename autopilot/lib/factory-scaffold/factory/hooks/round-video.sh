#!/usr/bin/env bash
# Record a walkthrough video of the current iterate-lane round against the
# preview deploy. Demo artifact, not a gate: recording problems must not block
# the feedback loop, so only a missing preview is fatal. Recording itself is
# deterministic Playwright (video always on), using e2e/tour.spec.* if present,
# else the acceptance specs, else a generic page tour.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true
source factory/hooks/lib-e2e.sh

source factory-preview.env
: "${PREVIEW_URL:?preview-deploy.sh must run first}"

# Namespace artifacts per run; one subdir per feedback round.
ARTIFACTS_DIR="factory-artifacts${FABRO_RUN_ID:+/$FABRO_RUN_ID}"
ROUND=$(( $(find "$ARTIFACTS_DIR" -maxdepth 1 -type d -name 'round-*' 2>/dev/null | wc -l | tr -d ' ') + 1 ))
ROUND_DIR="$ARTIFACTS_DIR/round-$ROUND"
mkdir -p "$ROUND_DIR"

ensure_playwright || true
if ! ls e2e/tour.spec.* e2e/*.spec.* >/dev/null 2>&1; then
  # No specs yet (early rounds) — generic tour: open the app, linger, scroll.
  mkdir -p e2e
  cat > e2e/tour.spec.mjs <<'EOF'
import { test } from '@playwright/test';
test('walkthrough tour',
  { annotation: { type: 'description', description: 'Обзорный проход по приложению в текущем состоянии раунда: открываем главный экран и прокручиваем содержимое. Демонстрация прогресса, не приёмочный тест.' } },
  async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(3000);
    await page.mouse.wheel(0, 800);
    await page.waitForTimeout(2000);
  });
EOF
fi
TOUR_ARGS=()
ls e2e/tour.spec.* >/dev/null 2>&1 && TOUR_ARGS=(--grep "walkthrough tour")
run_recorded_e2e "$PREVIEW_URL" "$ROUND_DIR" "${TOUR_ARGS[@]}" \
  || echo "WARN: round recording had failures — review the preview manually"

# This output is what the operator sees at the iterate gate.
echo "=================================================="
echo "ROUND $ROUND ARTIFACTS"
echo "Preview:  $PREVIEW_URL"
echo
cat "$ROUND_DIR/VIDEOS.md" 2>/dev/null || { echo "This round's video:"; print_video_list "$ROUND_DIR"; }
echo "Earlier rounds: $ARTIFACTS_DIR/round-*/"
echo "=================================================="
