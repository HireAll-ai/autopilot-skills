#!/usr/bin/env bash
# Local check of how /autoship merges a PR stack (autoship.md Steps 0.5, 4 and 4.1), no GitHub needed.
# A bare repo stands in for GitHub: its post-receive hook closes the open PRs based on a deleted
# branch, as GitHub did to ai-backlog#310. test/bin/gh is a gh stub that keeps PRs in files and logs
# every call. The step functions below are the command's steps with the placeholders filled in —
# change them together with autoship.md.
#
# Usage: autopilot/test/stacked-merge.sh [scenario …]   (default: all; KEEP=1 keeps the temp dirs)
#   old-delete-branch  3.1.0's `gh pr merge --delete-branch` — expected to close the stacked PRs
#   stack              a two-PR stack plus someone else's PR on the bottom branch, shipped in turn
#   rebased-base       the bottom PR was rebased after the second one branched
#   edit-fails         a retarget fails → the branch must stay
# Exit 0 when every check passes, 1 otherwise. Needs git ≥ 2.28 and jq.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
command -v git >/dev/null && command -v jq >/dev/null || { echo "needs git and jq" >&2; exit 2; }
export PATH="$HERE/bin:$PATH"
# keep the user's git config (signing, hooks, default branch) out of it
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
ZERO=0000000000000000000000000000000000000000
FAILS=0 SIMS=""
trap '[ -n "${KEEP:-}" ] || rm -rf $SIMS' EXIT

ok() { echo "  ok      $*"; }
nok() { echo "  FAIL    $*"; FAILS=$((FAILS + 1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else nok "$what"; fi; }
say() { echo "   · $*"; }
g() { git -C "$W" "$@"; }
pr_field() { sed -n "s/^$2=//p" "$SIM/prs/$1"; }
is_pr() { [ "$(pr_field "$1" state)" = "$2" ] && [ "$(pr_field "$1" base)" = "$3" ]; }
on_remote() { git --git-dir="$SIM/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
logged() { grep -qE -- "$1" "$SIM/calls.log"; }
# the patterns' first matches in calls.log come in this order
in_order() {
  local prev=0 n
  for p in "$@"; do
    n=$(grep -nE -m1 -- "$p" "$SIM/calls.log" | cut -d: -f1); [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1; prev=$n
  done
}
# nothing closed, nothing deleted under an open PR, gh never asked to delete the branch itself
invariants() {
  check "no PR closed" bash -c "! grep -qx 'state=CLOSED' '$SIM'/prs/*"
  check "no branch deleted while an open PR was based on it" bash -c "! grep -q 'github: CLOSED' '$SIM/calls.log'"
  check "no gh pr merge --delete-branch" bash -c "! grep -qE 'gh pr merge .*--delete-branch' '$SIM/calls.log'"
}

# --- a fresh "GitHub" with the stack: #1 stack/one → main (its 2nd commit edits the 1st's line),
#     #2 stack/two → stack/one, #3 other/dep → stack/one (someone else's)
setup() {
  SIM=$(mktemp -d "${TMPDIR:-/tmp}/stacked-merge.XXXXXX"); export SIM; SIMS="$SIMS $SIM"; W="$SIM/work"
  git init -q --bare -b main "$SIM/origin.git"
  { echo '#!/usr/bin/env bash'; echo "SIM='$SIM'"; cat <<'EOF'
seq_next() { local n; n=$(( $(cat "$SIM/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$SIM/seq"; printf '%02d' "$n"; }
while read -r old new ref; do
  [ "$new" = 0000000000000000000000000000000000000000 ] || continue
  b=${ref#refs/heads/}; echo "$(seq_next) github: branch $b deleted" >> "$SIM/calls.log"
  for f in "$SIM"/prs/*; do
    grep -qx 'state=OPEN' "$f" && grep -qxF "base=$b" "$f" || continue
    sed 's/^state=OPEN$/state=CLOSED/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "$(seq_next) github: CLOSED #${f##*/} — its base $b was deleted" >> "$SIM/calls.log"
  done
done
EOF
  } > "$SIM/origin.git/hooks/post-receive"
  chmod +x "$SIM/origin.git/hooks/post-receive"
  git clone -q "$SIM/origin.git" "$W" 2>/dev/null
  g checkout -q -b main; commit README "app" "chore: init"; g push -q origin main
  g checkout -q -b stack/one; commit feature.txt "x = 1" "feat: add x"; commit feature.txt "x = 2" "fix: x is 2"
  g push -q -u origin stack/one
  g checkout -q -b stack/two; commit other.txt "y" "feat: add y"; g push -q -u origin stack/two
  g checkout -q -b other/dep stack/one; commit dep.txt "z" "feat: add z"; g push -q -u origin other/dep
  mkdir "$SIM/prs"
  pr 1 main stack/one "feat: x"; pr 2 stack/one stack/two "feat: y"; pr 3 stack/one other/dep "feat: z (not ours)"
  : > "$SIM/calls.log"
}
commit() { printf '%s\n' "$2" > "$W/$1"; g add "$1"; g commit -q -m "$3"; }
pr() { printf 'state=OPEN\nbase=%s\nhead=%s\ntitle=%s\nheadoid=\nmerge=\n' "$2" "$3" "$4" > "$SIM/prs/$1"; }

# --- autoship Step 4 + 4.1 for PR $1 (<base> = main, deleteBranchOnMerge = true)
step4() {
  local n=$1 base=main head head_sha merge_sha left u
  read -r head head_sha < <(gh pr view "$n" --json headRefName,headRefOid --jq '"\(.headRefName) \(.headRefOid)"')
  echo "$head_sha" > "$SIM/head-sha.$n"
  gh pr merge "$n" --squash >/dev/null
  merge_sha=$(gh pr view "$n" --json mergeCommit --jq '.mergeCommit.oid // "ABORT: no merge commit SHA — did the merge land?"')
  case "$merge_sha" in ABORT*) say "#$n: $merge_sha"; return 1;; esac
  for u in $(gh pr list --base "$head" --state open --json url --jq '.[].url'); do
    if gh pr edit "$u" --base "$base" >/dev/null 2>&1; then say "#$n merged; retargeted ${u##*/} → $base"
    else say "#$n merged; retarget of ${u##*/} failed"; fi
  done
  left=$(gh pr list --base "$head" --state open --json url --jq length)
  if [ "$left" = 0 ]; then g push -q origin --delete "$head"; say "deleted $head"
  else say "kept $head: $left open PR(s) still based on it"; fi
}

# --- autoship Step 0.5 for a stacked PR whose base PR ($2) merged in this run
step05_stacked() {
  local branch=$1 old
  old=$(cat "$SIM/head-sha.$2")
  g checkout -q "$branch"; g fetch -q --prune origin main
  if g merge-base --is-ancestor origin/main HEAD; then return 0; fi
  if ! g merge-base --is-ancestor "$old" HEAD; then
    # the base PR was rebased after this one branched: the commit just below this PR's oldest own one
    old=$(g rev-parse "$(g log --format='%H %s' origin/main..HEAD | grep ' feat: add y$' | cut -d' ' -f1)^")
    say "$branch: <head-sha> not in its history → <old base head> = ${old:0:7}"
  fi
  g rebase -q --onto origin/main "$old" && g push -q --force-with-lease origin HEAD
}

own_commits() { [ "$(g log --format=%s "origin/main..origin/$1" | tr '\n' ';')" = "$2" ]; }
main_has() { [ "$(g show "origin/main:$1")" = "$2" ]; }

scenario_old-delete-branch() {
  setup
  gh pr merge 1 --squash --delete-branch >/dev/null
  # expected to break the stack: that's the bug 3.1.1 fixes, and proof the hook models GitHub
  check "3.1.0 --delete-branch closes #2 and #3 (expected failure, reproduced)" \
    bash -c "grep -qx 'state=CLOSED' '$SIM/prs/2' && grep -qx 'state=CLOSED' '$SIM/prs/3'"
}

scenario_stack() {
  setup
  step4 1
  check "#2 open, based on main" is_pr 2 OPEN main
  check "#3 (not ours) open, based on main" is_pr 3 OPEN main
  check "stack/one deleted" bash -c "! git --git-dir='$SIM/origin.git' rev-parse -q --verify refs/heads/stack/one"
  check "order: merge #1 → list on stack/one → edit #2 → recount → delete" in_order \
    '^[0-9]+ gh pr merge 1 --squash$' 'gh pr list --base stack/one .*\.\[\]\.url' \
    'gh pr edit [^ ]*/pull/2 --base main' 'gh pr list --base stack/one .*length' 'github: branch stack/one deleted'
  check "order: list on stack/one → edit #3 → recount" in_order \
    'gh pr list --base stack/one .*\.\[\]\.url' 'gh pr edit [^ ]*/pull/3 --base main' 'gh pr list --base stack/one .*length'

  git clone -q "$SIM/origin.git" "$SIM/probe"
  check "plain 'git rebase origin/main' of stack/two conflicts (why Step 0.5 uses --onto)" \
    bash -c "cd '$SIM/probe' && git checkout -q stack/two && ! git rebase -q origin/main"
  step05_stacked stack/two 1
  check "rebase --onto leaves only #2's own commit" own_commits stack/two "feat: add y;"
  step4 2
  check "#1 and #2 merged" bash -c "grep -qx 'state=MERGED' '$SIM/prs/1' && grep -qx 'state=MERGED' '$SIM/prs/2'"
  g fetch -q origin
  check "main: init, then #1, then #2" bash -c "[ \"\$(git -C '$W' log --format=%s origin/main | tr '\n' ';')\" = 'feat: y (#2);feat: x (#1);chore: init;' ]"
  check "main has feature.txt = 'x = 2' and other.txt = 'y'" bash -c "[ \"\$(git -C '$W' show origin/main:feature.txt)\" = 'x = 2' ] && [ \"\$(git -C '$W' show origin/main:other.txt)\" = y ]"
  check "remote branches left: main, other/dep" bash -c "[ \"\$(git --git-dir='$SIM/origin.git' for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' ')\" = 'main other/dep ' ]"
  invariants
}

scenario_rebased-base() {
  setup
  g checkout -q main; commit hotfix.txt "h" "fix: hotfix"; g push -q origin main
  g checkout -q stack/one; g rebase -q origin/main; g push -q --force-with-lease origin stack/one   # #1's Step 0.5
  step4 1
  check "#2 open, based on main" is_pr 2 OPEN main
  step05_stacked stack/two 1
  check "rebase --onto (fallback) leaves only #2's own commit" own_commits stack/two "feat: add y;"
  step4 2
  g fetch -q origin
  check "main: init, hotfix, #1, #2" bash -c "[ \"\$(git -C '$W' log --format=%s origin/main | tr '\n' ';')\" = 'feat: y (#2);feat: x (#1);fix: hotfix;chore: init;' ]"
  invariants
}

scenario_edit-fails() {
  setup
  GH_STUB_FAIL_EDIT=3 step4 1
  check "#2 retargeted to main" is_pr 2 OPEN main
  check "#3 still open on stack/one" is_pr 3 OPEN stack/one
  check "stack/one kept" on_remote stack/one
  check "no delete of stack/one" bash -c "! grep -q 'github: branch stack/one deleted' '$SIM/calls.log'"
  invariants
}

ALL="old-delete-branch stack rebased-base edit-fails"
for s in ${*:-$ALL}; do
  case " $ALL " in *" $s "*) ;; *) echo "unknown scenario: $s (have: $ALL)" >&2; exit 2;; esac
  echo "$s"
  "scenario_$s" || nok "$s stopped early (exit $?)"
  [ -z "${KEEP:-}" ] || echo "   (kept: $SIM)"
done
echo
if [ "$FAILS" = 0 ]; then echo "stacked-merge: all checks passed"; else echo "stacked-merge: $FAILS check(s) failed"; exit 1; fi
