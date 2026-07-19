#!/usr/bin/env bash
# Shared deterministic e2e machinery. Recording is guaranteed by Playwright's
# video:'on' in factory/e2e/playwright.config.mjs — never by agent goodwill.
# Source this from hooks; do not execute directly.

# Namespace for this run's artifacts. fabro does not export a run-id env var
# to command stages, so fall back to the branch name — unique per run once
# managed run branches are enabled ([run.run_branch] in workflow.toml).
run_namespace() {
  if [[ -n "${FABRO_RUN_ID:-}" ]]; then
    echo "$FABRO_RUN_ID"
    return
  fi
  # Note: a pipeline's exit code is the last command's, so `git … || echo` can
  # never fire on git failure — capture first, then default.
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"
  echo "${branch:-unscoped}"
}

# Install @playwright/test + chromium if the repo lacks them. Commits the
# dependency so the run branch stays reproducible.
ensure_playwright() {
  [[ -f package.json ]] || npm init -y >/dev/null
  if ! node -e "require.resolve('@playwright/test')" >/dev/null 2>&1; then
    npm i -D @playwright/test
    git add package.json package-lock.json 2>/dev/null || true
    git commit -m "e2e: add @playwright/test (factory infra)" >/dev/null 2>&1 || true
  fi
  npx playwright install chromium
}

# If the repo has no e2e specs yet, have an agent author them from spec.md
# (code in the branch, reviewed like everything else), then commit.
ensure_e2e_specs() {
  ls e2e/*.spec.* >/dev/null 2>&1 && return 0
  mkdir -p e2e
  claude -p "Write Playwright specs under e2e/ covering every acceptance criterion \
from spec.md (fall back to the goal in the latest commits if spec.md is absent). \
Use baseURL-relative navigation (page.goto('/')), resilient selectors, and one test \
per criterion. EVERY test must carry a description annotation — \
test('title', { annotation: { type: 'description', description: '2-3 sentences: what \
the user does in this scenario and what is being verified' } }, fn) — it becomes the \
text shown next to that test's video. Also write e2e/README.md: a short narrative of \
the feature's logic and flows, the list of scenarios and why they cover the feature, \
and what is intentionally out of scope — the operator reads it to recall the whole \
feature. Do not configure video or browsers — the factory config handles that. \
Do not touch anything outside e2e/." \
    --permission-mode acceptEdits --allowedTools "Bash,Read,Write,Edit,Glob,Grep"
  ls e2e/*.spec.* >/dev/null 2>&1 || { echo "E2E: no specs were authored" >&2; return 1; }
  git add e2e && git commit -m "e2e: acceptance scenario specs" >/dev/null 2>&1 || true
}

# run_recorded_e2e <base_url> <out_dir> [extra playwright args...]
# Runs the specs with forced recording. Returns Playwright's exit code
# (tests failed => nonzero) but ALWAYS verifies videos exist — a run with no
# video is a failure regardless of test results.
run_recorded_e2e() {
  local base_url="$1" out_dir="$2" rc=0
  shift 2
  mkdir -p "$out_dir"
  E2E_BASE_URL="$base_url" E2E_OUT_DIR="$out_dir" \
    npx playwright test --config factory/e2e/playwright.config.mjs "$@" || rc=$?
  if ! find "$out_dir" -name '*.webm' 2>/dev/null | grep -q .; then
    echo "E2E: no video produced under $out_dir — treating as failure" >&2
    return 1
  fi
  return "$rc"
}

print_video_list() {
  find "$1" \( -name '*.mp4' -o -name '*.webm' \) 2>/dev/null | sed 's/^/  /'
}
