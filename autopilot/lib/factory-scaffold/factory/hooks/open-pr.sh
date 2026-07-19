#!/usr/bin/env bash
# Open a PR for the current branch with spec + artifacts linked.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true

BASE="${FACTORY_BASE_BRANCH:-main}"
BODY="Automated factory run.

Spec: see spec.md in this branch.
Preview: $(grep -o 'https://[^ ]*' factory-preview.env 2>/dev/null || echo 'n/a')
E2E video: factory-artifacts/

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

gh pr create --base "$BASE" --fill --body "$BODY" || gh pr view --json url -q .url
