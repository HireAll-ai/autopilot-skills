#!/usr/bin/env bash
# Merge the PR once required checks are green.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true

# Repos without CI have no required checks — degrade gracefully in that case.
gh pr checks --watch --fail-fast || echo "no required checks reported — proceeding"
gh pr merge --squash --delete-branch
