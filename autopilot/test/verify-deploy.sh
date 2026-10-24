#!/usr/bin/env bash
# Smoke test of lib/verify-deploy.sh, /autoship Step 5.1: it proves a merge is live, on the user's
# machine — a stock Mac runs it under /bin/bash 3.2. Each scenario runs it in a throwaway clone of a
# bare origin, the way /autoship does after a merge. No network: curl, gh and sleep on PATH are stubs
# that log their call to $CANNED/calls.log and answer from canned files in $CANNED:
#   curl   the build-id body of its Nth call, body.N, else body; neither → an HTTP error, as `curl -f`
#   gh     `repo view` → acme/app (no-repo → fails); `api …/actions/runs…` → runs.json (absent: no
#          runs); `run watch <id>` → the exit code in run.<id> (absent: 1)
#   sleep  the poll waits (15 s build-id, 20 s github-run) take 0.1 s; any other sleep is real
# A scenario that waits out the deadline sets .deploy.verify.timeoutSeconds to 1, or 2–3 when it needs
# 2–3 polls or more (the deadline counts whole seconds of `date +%s`, so a 1 s window can end at once);
# the others to 30.
#
# Usage: autopilot/test/verify-deploy.sh [scenario …]   (default: all; KEEP=1 keeps the temp dir)
#   usage           no <merge-sha>, no config, a config that isn't JSON, is empty or [] or can't be read
#                   (skipped as root), a timeoutSeconds that isn't a whole number of seconds from 0 to 86400
#                   (negative, past a day as a JSON number or a string, Arabic-Indic or fullwidth digits under
#                   a UTF-8 locale, skipped without one) → one message naming the range, build-id without
#                   buildIdUrl, an unknown mode, a missing AUTOPILOT_REPO, `gh repo view` failing → rc 2
#   none            mode none, set or by default → rc 10, UNVERIFIED, nothing polled; the same with LC_ALL naming
#                   a locale the system lacks (bash warns on stderr in every child), not rc 1
#   build-id        the merge (full or short sha) → rc 0; the build flips on the 2nd poll → rc 0; a later
#                   commit that contains it → rc 0, one only origin has after a fetch too; a revert of
#                   it → rc 10; an older or unknown commit until the deadline → rc 10; unknown, empty
#                   or not JSON → rc 12 with restartedAt, kept when a later poll fails; unreachable on every
#                   poll, 3 or more → rc 1; one failed poll, then the merge → rc 0; timeoutSeconds 0 → one
#                   poll, unreachable on it → rc 10
#   github-run      the deploy run green → rc 0, failed → rc 1; only the named workflow counts, by
#                   name or file; none named → every push run, listed twice; no run in time → rc 10;
#                   timeoutSeconds 0 → listed once, then rc 0 on a finished run, rc 10 on none
#   autopilot-repo  AUTOPILOT_REPO=<dir> from another cwd: <dir>'s config and git; <dir> without a
#                   config → rc 2
# Exit 0 when every check passes, 1 otherwise. Needs git ≥ 2.28 and jq.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VERIFY=$(cd "$HERE/../lib" && pwd)/verify-deploy.sh
command -v git >/dev/null && command -v jq >/dev/null || { echo "needs git and jq" >&2; exit 2; }
REAL_SLEEP=$(command -v sleep)
# -P: on macOS /var is /private/var, and git prints the repo root resolved
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/verify-deploy-test.XXXXXX")" && pwd -P)
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/home"
export CANNED="$T/canned"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
n=$(( $(cat "$CANNED/curl.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CANNED/curl.n"
echo "curl $*" >> "$CANNED/calls.log"
for f in "$CANNED/body.$n" "$CANNED/body"; do
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
done
echo "curl: (22) The requested URL returned error: 503" >&2; exit 22
EOF
cat > "$T/bin/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$CANNED/calls.log"
case "$1 $2" in
  "repo view") [ ! -e "$CANNED/no-repo" ] || { echo "gh: not a GitHub repository" >&2; exit 1; }; echo acme/app ;;
  "api "*) if [ -f "$CANNED/runs.json" ]; then cat "$CANNED/runs.json"; else echo '{"total_count":0,"workflow_runs":[]}'; fi ;;
  "run watch") exit "$(cat "$CANNED/run.$3" 2>/dev/null || echo 1)" ;;
  *) echo "gh stub: unsupported: gh $*" >&2; exit 2 ;;
esac
EOF
cat > "$T/bin/sleep" <<EOF
#!/bin/sh
echo "sleep \$*" >> "\$CANNED/calls.log"
case "\$*" in 15|20) set -- 0.1 ;; esac
exec '$REAL_SLEEP' "\$@"
EOF
chmod +x "$T/bin/curl" "$T/bin/gh" "$T/bin/sleep"
export PATH="$T/bin:$PATH" HOME="$T/home"
unset CLAUDE_CONFIG_DIR AUTOPILOT_REPO AUTOPILOT_CONFIG
# keep the user's git config (signing, hooks, default branch) out of it
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
URL=https://app.example.com/api/build
FAILS=0 RC=""
: > "$T/out"; : > "$T/err"

ok() { echo "  ok      $*"; }
nok() { echo "  FAIL    $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  skip    $*"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else nok "$what"; last_run; fi; }
last_run() {
  echo "          last run: rc=$RC"
  sed -n '1,5s/^/          stdout| /p' "$T/out"; sed -n '1,5s/^/          stderr| /p' "$T/err"
  sed -n '1,8s/^/          calls | /p' "$CANNED/calls.log" 2>/dev/null || true
}
# run <cmd …> — its stdout, stderr and exit code land in $T/out, $T/err and $RC
run() { RC=0; "$@" >"$T/out" 2>"$T/err" || RC=$?; }
in_dir() { local d=$1; shift; (cd "$d" && "$@"); }
rc_is() { [ "$RC" = "$1" ]; }
says() { rc_is "$1" && grep -qxF -- "$2" "$T/out"; }          # says <rc> <a whole line of stdout>
fails_with() { rc_is "$1" && grep -qF -- "$2" "$T/err"; }
fails_like() { rc_is "$1" && grep -qE -- "$2" "$T/err"; }     # … <an ERE for a line of stderr>
called() { [ "$(grep -cxF -- "$1" "$CANNED/calls.log" || true)" = "$2" ]; }   # called <call> <n times>
called_like() { [ "$(grep -c -- "$1" "$CANNED/calls.log" || true)" = "$2" ]; }  # … <regex> <n times>

# canned [file content …] — a fresh $CANNED holding these files: canned body '{"commit":"…"}'
canned() {
  rm -rf "$CANNED"; mkdir "$CANNED"; : > "$CANNED/calls.log"
  while [ $# -gt 0 ]; do printf '%s\n' "$2" > "$CANNED/$1"; shift 2; done
}
# deploy <dir> <deploy block as JSON> — writes <dir>'s config with that .deploy and base branch trunk
deploy() {
  jq -n --argjson deploy "$2" '{
    version: 1,
    tracker: { type: "none", mcp: "", keyPrefix: "", keyRequired: false },
    git: { baseBranch: "trunk", mergeStrategy: "squash", deleteBranchOnMerge: true,
           protection: { requiredChecks: ["check"], strict: false } },
    commands: { install: "", typecheck: "", test: "", build: "", dev: "", lint: null },
    review: { gate: "none", localReviewers: [] },
    deploy: $deploy,
    qa: {},
    rules: { docs: ["README.md"] }
  }' > "$1/.claude/autopilot.config.json" || nok "deploy: not a JSON block: $2"
}
# build_id <dir> [timeout] [extra .verify keys as JSON] — mode build-id against $URL
build_id() {
  local x=${3-}; [ -n "$x" ] || x='{}'   # not "${3:-{\}}": bash 3.2 keeps the backslash
  deploy "$1" "$(jq -n --arg url "$URL" --argjson t "${2:-30}" --argjson x "$x" \
    '{ trigger: "merge-to-base", verify: ({ mode: "build-id", buildIdUrl: $url, timeoutSeconds: $t } + $x) }')"
}
# github_run <dir> [workflow] [timeout] — mode github-run, the deploy workflow named or not
github_run() {
  deploy "$1" "$(jq -n --arg wf "${2-}" --argjson t "${3:-30}" \
    '{ trigger: "github-action", verify: ({ mode: "github-run", timeoutSeconds: $t } + (if $wf == "" then {} else { workflow: $wf } end)) }')"
}

# repos <dir> — a bare origin <dir>.git and its clone <dir> on trunk: the commits OLD → MERGE → LATER
# pushed, REVERT (reverts MERGE, on top of LATER) only on a local branch, and AHEAD (on top of LATER)
# pushed to origin from another clone, so <dir> doesn't have it until it fetches
repos() {
  local W=$1 O=$1.git X=$1-other
  git init -q --bare -b trunk "$O"
  git init -q -b trunk "$W"; git -C "$W" remote add origin "$O"; mkdir "$W/.claude"
  echo app > "$W/README"; git -C "$W" add README; git -C "$W" commit -q -m "chore: init"
  OLD=$(git -C "$W" rev-parse HEAD)
  echo shipped >> "$W/README"; git -C "$W" commit -qam "feat: the shipped PR (#7)"
  MERGE=$(git -C "$W" rev-parse HEAD)
  echo next > "$W/NEXT"; git -C "$W" add NEXT; git -C "$W" commit -q -m "feat: the PR merged next (#8)"
  LATER=$(git -C "$W" rev-parse HEAD)
  git -C "$W" push -q origin trunk
  git -C "$W" checkout -q -b revert; git -C "$W" revert --no-edit HEAD~1 >/dev/null
  REVERT=$(git -C "$W" rev-parse HEAD); git -C "$W" checkout -q trunk
  git clone -q "$O" "$X"; echo ahead > "$X/AHEAD"; git -C "$X" add AHEAD; git -C "$X" commit -q -m "feat: merged while we polled (#9)"
  AHEAD=$(git -C "$X" rev-parse HEAD); git -C "$X" push -q origin trunk
}

scenario_usage() {
  local W="$T/usage" C="$T/usage/.claude/autopilot.config.json"
  local range="verify-deploy: .deploy.verify.timeoutSeconds must be a whole number of seconds from 0 to 86400, got"
  repos "$W"; build_id "$W"; canned
  run in_dir "$W" "$VERIFY"
  check "no <merge-sha> → rc 2, usage on stderr" fails_with 2 "usage: verify-deploy.sh <merge-sha>"
  rm "$W/.claude/autopilot.config.json"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "no config → rc 2, its path on stderr" fails_with 2 "verify-deploy: no config at $W/.claude/autopilot.config.json"
  printf '%s\n' '{ "deploy": { "trigger": "merge-to-base",' > "$W/.claude/autopilot.config.json"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a config that isn't JSON → rc 2, named on stderr" fails_with 2 "verify-deploy: invalid JSON at $W/.claude/autopilot.config.json"
  : > "$W/.claude/autopilot.config.json"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "an empty config → rc 2, not one JSON object" fails_with 2 "verify-deploy: config at $W/.claude/autopilot.config.json is not one JSON object"
  echo '[]' > "$W/.claude/autopilot.config.json"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a config that is [] → rc 2, not one JSON object" fails_with 2 "verify-deploy: config at $W/.claude/autopilot.config.json is not one JSON object"
  if [ "$(id -u)" = 0 ]; then
    skip "a config it can't read (root reads any file)"
  else
    build_id "$W"; chmod 000 "$W/.claude/autopilot.config.json"
    run in_dir "$W" "$VERIFY" "$MERGE"
    check "a config it can't read → rc 2, cannot read" fails_with 2 "verify-deploy: cannot read config at $W/.claude/autopilot.config.json"
    chmod 644 "$W/.claude/autopilot.config.json"
  fi
  for t in '"10m"' 1.5 -5 true; do
    build_id "$W" "$t"; canned
    run in_dir "$W" "$VERIFY" "$MERGE"
    check "timeoutSeconds $t → rc 2, the key, the value and the range on stderr" fails_with 2 "$range '$(jq -r . <<<"$t")'"
    check "… nothing polled" bash -c "[ ! -s '$CANNED/calls.log' ]"
  done
  # written as is: jq would rewrite the literal on the way. jq 1.6 reads it back as 1e+20, jq 1.7 as written
  build_id "$W" '"__T__"'; sed 's/"__T__"/99999999999999999999/' "$C" > "$C.tmp"; mv "$C.tmp" "$C"; canned
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 99999999999999999999, a JSON number → rc 2, the range named" \
    fails_like 2 "^$range '(99999999999999999999|1e\\+20)'\$"
  check "… nothing polled" bash -c "[ ! -s '$CANNED/calls.log' ]"
  build_id "$W" "$(jq -n --arg t "PATH[\$(touch '$T/ran')]" '$t')"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds with a \$(…) in a subscript → rc 2, the command not run" bash -c "[ $RC = 2 ] && [ ! -e '$T/ran' ]"
  # glibc's en_US.UTF-8 has [0-9] match Arabic-Indic digits; C.UTF-8 doesn't, so it comes second
  local locales loc; locales=$(locale -a 2>/dev/null || true)
  loc=$(grep -m 1 -ixE 'en_US\.utf-?8' <<<"$locales" || grep -m 1 -ixE 'C\.utf-?8' <<<"$locales" || true)
  if [ -z "$loc" ]; then
    skip "timeoutSeconds in Arabic-Indic or fullwidth digits under a UTF-8 locale (neither en_US.UTF-8 nor C.UTF-8 here)"
  else
    for t in ٣٠ ３０; do   # Arabic-Indic, fullwidth
      build_id "$W" "\"$t\""; canned
      run in_dir "$W" env LC_ALL="$loc" "$VERIFY" "$MERGE"
      check "timeoutSeconds \"$t\" under LC_ALL=$loc → rc 2, the range named" fails_with 2 "$range '$t'"
      check "… nothing polled" bash -c "[ ! -s '$CANNED/calls.log' ]"
    done
  fi
  for t in 9223372036854775807 99999999999999999999 86401 000000000000000000086401; do
    build_id "$W" "\"$t\""; canned
    run in_dir "$W" "$VERIFY" "$MERGE"
    check "timeoutSeconds \"$t\" → rc 2, over the cap of a day, the range named" fails_with 2 "$range '$t'"
    check "… nothing polled" bash -c "[ ! -s '$CANNED/calls.log' ]"
  done
  build_id "$W" '"086400"'; canned body "{\"commit\":\"$MERGE\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds \"086400\": a day, a leading zero → polled, rc 0" says 0 "VERIFIED: $URL reports $MERGE"
  deploy "$W" '{ "trigger": "merge-to-base", "verify": { "mode": "build-id" } }'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "build-id without buildIdUrl → rc 2, named on stderr" fails_with 2 "mode=build-id needs .deploy.verify.buildIdUrl"
  deploy "$W" '{ "trigger": "merge-to-base", "verify": { "mode": "smoke-signal" } }'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "an unknown mode → rc 2, named on stderr" fails_with 2 "unknown deploy.verify.mode 'smoke-signal'"
  run in_dir "$W" env AUTOPILOT_REPO="$T/absent" "$VERIFY" "$MERGE"
  check "an AUTOPILOT_REPO that isn't there → rc 2" rc_is 2
  github_run "$W" Deploy; canned no-repo ""
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "github-run, \`gh repo view\` fails → rc 2, no runs listed" bash -c "[ $RC = 2 ] && ! grep -q '^gh api' '$CANNED/calls.log'"
}

scenario_none() {
  local W="$T/none"
  repos "$W"
  for block in '{ "trigger": "none" }' '{ "trigger": "merge-to-base" }' '{ "trigger": "merge-to-base", "verify": { "mode": "none" } }'; do
    deploy "$W" "$block"; canned
    run in_dir "$W" "$VERIFY" "$MERGE"
    check "deploy $block → rc 10, UNVERIFIED" says 10 "UNVERIFIED: deploy.verify.mode is none — nothing can confirm the build"
    check "… mode=none, nothing polled" bash -c "grep -qx 'verify-deploy: mode=none sha=$MERGE timeout=600s' '$T/out' && [ ! -s '$CANNED/calls.log' ]"
  done
  # glibc's bash warns `setlocale: LC_ALL: cannot change locale` on stderr at every start: the timeout
  # verify-deploy reads from a child must come from its stdout only
  run in_dir "$W" env LC_ALL=xx_XX.UTF-8 "$VERIFY" "$MERGE"
  check "LC_ALL=xx_XX.UTF-8, a locale the system lacks → rc 10, UNVERIFIED, timeout=600s" \
    bash -c "[ $RC = 10 ] && grep -qx 'verify-deploy: mode=none sha=$MERGE timeout=600s' '$T/out'"
}

scenario_build-id() {
  local W="$T/build-id" unknown=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  repos "$W"

  build_id "$W"; canned body "{\"commit\":\"$MERGE\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "the live build is the merge → rc 0, VERIFIED" says 0 "VERIFIED: $URL reports $MERGE"
  check "… polled $URL once, with curl -f and a 10 s cap" called "curl -fsS --max-time 10 $URL" 1
  check "… mode, sha and timeout on the first line" bash -c "[ \"\$(head -n 1 '$T/out')\" = 'verify-deploy: mode=build-id sha=$MERGE timeout=30s' ]"
  canned body "{\"commit\":\"${MERGE:0:7}\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "the merge's short sha → rc 0" says 0 "VERIFIED: $URL reports ${MERGE:0:7}"
  build_id "$W" 30 '{ "buildIdJq": ".build.sha" }'; canned body "{\"build\":{\"sha\":\"$MERGE\"},\"commit\":\"$OLD\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "buildIdJq .build.sha → read there, rc 0" says 0 "VERIFIED: $URL reports $MERGE"

  build_id "$W"; canned body.1 "{\"commit\":\"$OLD\"}" body "{\"commit\":\"$MERGE\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "the old build, then the merge on the 2nd poll → rc 0" says 0 "VERIFIED: $URL reports $MERGE"
  check "… 2 polls, one 15 s wait between them" bash -c "[ \"\$(cat '$CANNED/curl.n')\" = 2 ] && [ \"\$(grep -cx 'sleep 15' '$CANNED/calls.log')\" = 1 ]"

  canned body "{\"commit\":\"$LATER\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a later commit that contains the merge → rc 0" says 0 "VERIFIED: $URL reports $LATER (contains $MERGE)"
  check "… in a single poll" called "curl -fsS --max-time 10 $URL" 1
  canned body "{\"commit\":\"$AHEAD\"}"
  check "a later commit only origin has: not in the clone yet" bash -c "! git -C '$W' cat-file -e '$AHEAD^{commit}'"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "… → trunk fetched, it contains the merge → rc 0" says 0 "VERIFIED: $URL reports $AHEAD (contains $MERGE)"
  check "… the clone has it now" git -C "$W" cat-file -e "$AHEAD^{commit}"
  canned body "{\"commit\":\"$REVERT\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a commit that contains the merge but reverts it → rc 10, UNVERIFIED" \
    says 10 "UNVERIFIED: $URL reports $REVERT, which contains $MERGE but also reverts it"

  build_id "$W" 1; canned body "{\"commit\":\"$OLD\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "the old build until the deadline → rc 10, UNVERIFIED" \
    says 10 "UNVERIFIED: $URL still reports $OLD (not $MERGE or a commit that contains it) after 1s"
  check "… polled until then, 15 s waits between polls" bash -c "[ \"\$(cat '$CANNED/curl.n')\" -ge 1 ] && ! grep -v -e '^curl ' -e '^sleep 15\$' '$CANNED/calls.log'"
  canned body "{\"commit\":\"$unknown\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a commit neither the clone nor origin has → rc 10, not an error" \
    says 10 "UNVERIFIED: $URL still reports $unknown (not $MERGE or a commit that contains it) after 1s"

  build_id "$W" 1 '{ "restartedAtJq": ".restartedAt" }'; canned body '{"commit":"unknown","restartedAt":"2026-10-21T02:00:00Z"}'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "commit unknown, restartedAtJq set → rc 12, restartedAt printed" \
    says 12 "COMMIT_UNKNOWN: $URL answers but the commit reads 'unknown'; restartedAt=2026-10-21T02:00:00Z"
  build_id "$W" 1; canned body '{"commit":"","restartedAt":"2026-10-21T02:00:00Z"}'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "commit empty, no restartedAtJq → rc 12, restartedAt=<n/a>" \
    says 12 "COMMIT_UNKNOWN: $URL answers but the commit reads '<empty>'; restartedAt=<n/a>"
  build_id "$W" 1 '{ "restartedAtJq": ".restartedAt" }'; canned body '<html><body>Deploying…</body></html>'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "a body that isn't JSON → rc 12, the commit reads empty" \
    says 12 "COMMIT_UNKNOWN: $URL answers but the commit reads '<empty>'; restartedAt=<n/a>"

  build_id "$W" 2 '{ "restartedAtJq": ".restartedAt" }'; canned body.1 '{"commit":"unknown","restartedAt":"2026-10-21T02:00:00Z"}'
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "commit unknown, then unreachable until the deadline → rc 12, the answer's restartedAt kept" \
    says 12 "COMMIT_UNKNOWN: $URL answers but the commit reads 'unknown'; restartedAt=2026-10-21T02:00:00Z"
  check "… polled again after it" bash -c "[ \"\$(cat '$CANNED/curl.n')\" -ge 2 ]"

  build_id "$W" 3; canned
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "unreachable on every poll of a 3 s window → rc 1, BROKEN" says 1 "BROKEN: $URL unreachable for the whole 3s window"
  check "… 3 polls or more" bash -c "[ \"\$(cat '$CANNED/curl.n')\" -ge 3 ]"
  build_id "$W"; canned body.2 "{\"commit\":\"$MERGE\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "unreachable on the 1st poll, the merge on the 2nd → rc 0, VERIFIED" says 0 "VERIFIED: $URL reports $MERGE"
  check "… 2 polls, one 15 s wait between them" bash -c "[ \"\$(cat '$CANNED/curl.n')\" = 2 ] && [ \"\$(grep -cx 'sleep 15' '$CANNED/calls.log')\" = 1 ]"

  build_id "$W" 0; canned body "{\"commit\":\"$MERGE\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 0, the merge live → rc 0" says 0 "VERIFIED: $URL reports $MERGE"
  check "… one poll, no wait" bash -c "[ \"\$(cat '$CANNED/curl.n')\" = 1 ] && ! grep -q '^sleep' '$CANNED/calls.log'"
  canned body "{\"commit\":\"$OLD\"}"
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 0, the old build → rc 10, UNVERIFIED" \
    says 10 "UNVERIFIED: $URL still reports $OLD (not $MERGE or a commit that contains it) after 0s"
  check "… one poll, no wait" bash -c "[ \"\$(cat '$CANNED/curl.n')\" = 1 ] && ! grep -q '^sleep' '$CANNED/calls.log'"
  canned
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 0, unreachable on its one poll → rc 10, UNVERIFIED, not BROKEN" \
    says 10 "UNVERIFIED: $URL unreachable on the only poll(s) in a 0s window"
  check "… one poll, no wait" bash -c "[ \"\$(cat '$CANNED/curl.n')\" = 1 ] && ! grep -q '^sleep' '$CANNED/calls.log'"
}

scenario_github-run() {
  local W="$T/github-run" runs
  repos "$W"
  runs=$(jq -n --arg sha "$MERGE" '{ total_count: 2, workflow_runs: [
    { id: 101, name: "CI", path: ".github/workflows/ci.yml", head_sha: $sha },
    { id: 102, name: "Deploy", path: ".github/workflows/deploy.yml", head_sha: $sha } ] }')

  github_run "$W" Deploy; canned runs.json "$runs" run.101 1 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "workflow Deploy green → rc 0, VERIFIED" says 0 "VERIFIED: push run(s) for $MERGE green: Deploy"
  check "… asked for the push runs of the merge on trunk" \
    called "gh api repos/acme/app/actions/runs?head_sha=$MERGE&event=push&branch=trunk&per_page=50" 1
  check "… watched run 102 only, not CI's 101" \
    bash -c "grep -q '^gh run watch 102 --exit-status' '$CANNED/calls.log' && ! grep -q '^gh run watch 101' '$CANNED/calls.log'"
  github_run "$W" deploy.yml; canned runs.json "$runs" run.101 1 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "the workflow named by its file, deploy.yml → rc 0" says 0 "VERIFIED: push run(s) for $MERGE green: Deploy"
  github_run "$W" Deploy; canned runs.json "$runs" run.101 0 run.102 1
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "workflow Deploy failed → rc 1, BROKEN, the run named" says 1 "BROKEN: run(s) failed: 102(Deploy)"

  github_run "$W"; canned runs.json "$runs" run.101 0 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "no workflow named, every push run green → rc 0, all named" says 0 "VERIFIED: push run(s) for $MERGE green: CI,Deploy"
  check "… runs listed twice, 20 s apart, both watched" \
    bash -c "[ \"\$(grep -c '^gh api ' '$CANNED/calls.log')\" = 2 ] && grep -qx 'sleep 20' '$CANNED/calls.log' \
      && [ \"\$(grep -c '^gh run watch ' '$CANNED/calls.log')\" = 2 ]"
  canned runs.json "$runs" run.101 1 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "no workflow named, CI failed → rc 1, BROKEN" says 1 "BROKEN: run(s) failed: 101(CI)"
  deploy "$W" '{ "trigger": "github-action" }'; canned runs.json "$runs" run.101 0 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "trigger github-action, no verify block → mode github-run, rc 0" \
    bash -c "[ $RC = 0 ] && grep -qx 'verify-deploy: mode=github-run sha=$MERGE timeout=600s' '$T/out'"

  github_run "$W" Deploy 1; canned
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "no run until the deadline → rc 10, UNVERIFIED" says 10 "UNVERIFIED: no push run of 'Deploy' observed for $MERGE within 1s"
  check "… nothing watched" bash -c "! grep -q '^gh run watch' '$CANNED/calls.log'"

  github_run "$W" Deploy 0; canned runs.json "$runs" run.101 1 run.102 0
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 0, the deploy run already finished green → rc 0, VERIFIED" \
    says 0 "VERIFIED: push run(s) for $MERGE green: Deploy"
  check "… listed once, no wait" bash -c "[ \"\$(grep -c '^gh api ' '$CANNED/calls.log')\" = 1 ] && ! grep -q '^sleep' '$CANNED/calls.log'"
  canned
  run in_dir "$W" "$VERIFY" "$MERGE"
  check "timeoutSeconds 0, no run → rc 10, UNVERIFIED" says 10 "UNVERIFIED: no push run of 'Deploy' observed for $MERGE within 0s"
  check "… listed once, no wait" bash -c "[ \"\$(grep -c '^gh api ' '$CANNED/calls.log')\" = 1 ] && ! grep -q '^sleep' '$CANNED/calls.log'"
}

scenario_autopilot-repo() {
  local W="$T/ap-repo" B="$T/ap-other" E="$T/ap-elsewhere"
  repos "$W"; repos "$B"; mkdir "$E"
  build_id "$W"; deploy "$B" '{ "trigger": "none" }'
  canned body "{\"commit\":\"$(git -C "$W" rev-parse trunk)\"}"
  local merge; merge=$(git -C "$W" rev-parse trunk~1)
  run in_dir "$E" env AUTOPILOT_REPO="$W" "$VERIFY" "$merge"
  check "outside any repo: <dir>'s config and git → contains the merge, rc 0" bash -c "[ $RC = 0 ] && grep -q '^VERIFIED: .* (contains $merge)' '$T/out'"
  run in_dir "$B" env AUTOPILOT_REPO=../ap-repo "$VERIFY" "$merge"
  check "inside another repo (mode none there), a relative <dir> → <dir>'s build-id, rc 0" \
    bash -c "[ $RC = 0 ] && grep -qx 'verify-deploy: mode=build-id sha=$merge timeout=30s' '$T/out'"
  run in_dir "$W" env AUTOPILOT_REPO="$E" "$VERIFY" "$merge"
  check "a <dir> without a config, from a repo with one → rc 2, <dir>'s path on stderr" \
    fails_with 2 "verify-deploy: no config at $E/.claude/autopilot.config.json"
}

echo "verify-deploy.sh under bash $(bash -c 'echo "$BASH_VERSION"')"
ALL="usage none build-id github-run autopilot-repo"
for s in ${*:-$ALL}; do
  case " $ALL " in *" $s "*) ;; *) echo "unknown scenario: $s (have: $ALL)" >&2; exit 2;; esac
  echo "$s"
  "scenario_$s" || nok "$s stopped early (exit $?)"
done
[ -z "${KEEP:-}" ] || echo "(kept: $T)"
echo
if [ "$FAILS" = 0 ]; then echo "verify-deploy: all checks passed"; else echo "verify-deploy: $FAILS check(s) failed"; exit 1; fi
