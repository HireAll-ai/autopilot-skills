#!/usr/bin/env bash
# typecheck.sh — run the project's `.commands.typecheck`, at most once per working tree.
#
# /autodev and /autoship re-assert "<typecheck> must pass" at every gate (before a push, after a
# rebase, before the merge). On an unchanged tree that is the same multi-minute check repeated for
# one signal. This wrapper keys a cache on the hash of the full working tree (tracked + untracked,
# respecting .gitignore): an identical tree that already passed is a no-op, any change re-runs it.
#
# Usage: typecheck.sh [--force]
# Exit:  0 = passed (or cached pass, or no typecheck configured); otherwise the typecheck's own code.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CMD="$("$SCRIPT_DIR/autopilot-config.sh" get '.commands.typecheck' '')"
if [ -z "$CMD" ]; then echo "typecheck: skipped — .commands.typecheck is empty"; exit 0; fi

# Hash the working tree without touching the real index: copy it, stage everything into the copy.
_tree_hash() {
  local idx; idx="$(mktemp)"
  cp "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || rm -f "$idx"
  GIT_INDEX_FILE="$idx" git add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git write-tree
  rm -f "$idx"
}

CACHE_DIR="$(git rev-parse --absolute-git-dir)/autopilot"   # per-worktree, never committed
CACHE="$CACHE_DIR/typecheck-ok"
TREE="$(_tree_hash)"

if [ "${1-}" != "--force" ] && [ -f "$CACHE" ] && grep -qx "$TREE" "$CACHE"; then
  echo "typecheck: cached pass — this exact tree ($TREE) already passed '$CMD'"
  exit 0
fi

echo "typecheck: running '$CMD' (tree $TREE)"
bash -c "$CMD"
mkdir -p "$CACHE_DIR"
{ echo "$TREE"; tail -n 49 "$CACHE" 2>/dev/null || true; } >"$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
echo "typecheck: pass"
