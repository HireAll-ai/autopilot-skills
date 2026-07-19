#!/usr/bin/env bash
# Open a PR for the current branch with spec + artifacts linked.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true

BASE="${FACTORY_BASE_BRANCH:-main}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# The e2e stage commits specs after the preview push — always push the final
# state first: gh pr create aborts non-interactively on an unpushed branch.
git push -u origin "$BRANCH"

BODY="Automated factory run.

Spec: see spec.md in this branch.
Preview: $(grep -oE 'https?://[^ ]*' factory-preview.env 2>/dev/null || echo 'n/a')
E2E video: factory-artifacts/

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

gh pr create --base "$BASE" --head "$BRANCH" --fill --body "$BODY" || gh pr view --json url -q .url
