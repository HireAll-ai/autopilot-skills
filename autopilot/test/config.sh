#!/usr/bin/env bash
# Smoke test of lib/autopilot-config.sh and lib/typecheck.sh: every /autodev, /autoship and /autopilot
# run starts with them, on the user's machine — a stock Mac runs them under /bin/bash 3.2. Each scenario
# runs the scripts in throwaway git repos the way the commands do. No network: gh, curl and npx on PATH
# are stubs that log their call and fail, so `detect` stays offline and `validate` takes its jq
# fallback — only in the detect scenario does curl answer the backlog probe, from canned files. HOME is
# a temp dir, so the only ~/.claude.json read is the one the detect scenario writes.
#
# Usage: autopilot/test/config.sh [scenario …]   (default: all; KEEP=1 keeps the temp dir)
#   load            valid config + init marker → rc 0 and the config / a config that isn't JSON or is []:
#                   load, ensure, dump → rc 2, the cause named, nothing on stdout; --reconfigure → rc 3
#                   and a draft, broken or not / one it can't read (skipped as root): load and ensure
#                   --reconfigure → rc 2, fix its permissions / no config → rc 3 and a detected draft /
#                   no init marker → rc 4
#   get             get <filter> [default], path, exists, dump; get on a config that isn't JSON, is
#                   empty or [] or can't be read (skipped as root) → rc 2, the cause named
#   validate        a valid config, then broken ones: not JSON, empty, [], keys missing, another version;
#                   a timeoutSeconds past a day, not digits, negative, in Arabic-Indic digits under a UTF-8
#                   locale (skipped without one) → rc 2, the range named; absent, null, 0, 86400, "30" → rc 0;
#                   timeout prints its seconds: 600 by default, "030" → 30, 30.0 → 30, -0 → 0
#   autopilot-repo  AUTOPILOT_REPO=<dir> from another cwd: outside any repo, inside another repo
#   typecheck       empty command → skipped; pass → cached pass; a changed tree or --force → re-run;
#                   a failing command → its exit code; a config that isn't JSON → rc 2, not skipped
#   detect          the backlog probe: where the MCP server comes from (local scope, an approved
#                   .mcp.json, user scope; AUTOPILOT_BACKLOG_URL over them), ${BACKLOG_*} expansion, the
#                   token replacing Authorization, up / refused / down / unusable and the draft of each
# Exit 0 when every check passes, 1 otherwise. Needs git ≥ 2.28 and jq.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG=$(cd "$HERE/../lib" && pwd)/autopilot-config.sh
TYPECHECK=$(dirname "$CONFIG")/typecheck.sh
command -v git >/dev/null && command -v jq >/dev/null || { echo "needs git and jq" >&2; exit 2; }
# -P: on macOS /var is /private/var, and git prints the repo root resolved
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/config-test.XXXXXX")" && pwd -P)
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
mkdir "$T/bin" "$T/home"
for tool in gh curl npx; do
  { echo '#!/bin/sh'; echo "echo \"$tool \$*\" >> '$T/stubs.log'"; echo "echo '$tool: stubbed out by test/config.sh' >&2; exit 1"; } > "$T/bin/$tool"
  chmod +x "$T/bin/$tool"
done
# … except while the detect scenario puts a reply in $T/curl: then curl records the URL, the repoPath
# and the headers it read on stdin, and answers its body plus the code, the way -w '\n%{http_code}'
# prints them; code 000 is no answer (curl exits 7)
cat > "$T/bin/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> '$T/stubs.log'
C='$T/curl'
if [ ! -f "\$C/code" ]; then echo 'curl: stubbed out by test/config.sh' >&2; exit 1; fi
for a in "\$@"; do
  case "\$a" in http://*|https://*) echo "\$a" > "\$C/url";; repoPath=*) echo "\${a#repoPath=}" > "\$C/repoPath";; esac
done
cat > "\$C/headers"
code=\$(cat "\$C/code")
[ "\$code" != 000 ] || { printf '\n000'; exit 7; }
cat "\$C/body"; printf '\n%s' "\$code"
EOF
export PATH="$T/bin:$PATH" HOME="$T/home"
unset CLAUDE_CONFIG_DIR AUTOPILOT_REPO AUTOPILOT_CONFIG AUTOPILOT_BACKLOG_URL AUTOPILOT_BACKLOG_TOKEN
# keep the user's git config (signing, hooks, default branch) out of it
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@example.com
# every typecheck command below appends its cwd here: one line per run
export TC_RUNS="$T/typecheck.runs"
FAILS=0 RC=""
: > "$T/out"; : > "$T/err"

ok() { echo "  ok      $*"; }
nok() { echo "  FAIL    $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  skip    $*"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else nok "$what"; last_run; fi; }
last_run() {
  echo "          last run: rc=$RC"
  sed -n '1,5s/^/          stdout| /p' "$T/out"; sed -n '1,5s/^/          stderr| /p' "$T/err"
}
# run <cmd …> — its stdout, stderr and exit code land in $T/out, $T/err and $RC
run() { RC=0; "$@" >"$T/out" 2>"$T/err" || RC=$?; }
in_dir() { local d=$1; shift; (cd "$d" && "$@"); }
rc_is() { [ "$RC" = "$1" ]; }
got() { rc_is 0 && [ "$(cat "$T/out")" = "$1" ]; }
out_has() { grep -qF -- "$1" "$T/out"; }
fails_with() { rc_is "$1" && grep -qF -- "$2" "$T/err"; }
printed_config() { rc_is 0 && cmp -s "$T/out" "$1/.claude/autopilot.config.json"; }
ran() { [ "$(grep -cxF "$1" "$TC_RUNS" || true)" = "$2" ]; }   # ran <repo> <n>: its typecheck ran n times

# a config with .commands.typecheck = $1 and .git.baseBranch = trunk (not a default anywhere)
fixture() {
  jq -n --arg tc "$1" '{
    version: 1,
    tracker: { type: "none", mcp: "", keyPrefix: "", keyRequired: false },
    git: { baseBranch: "trunk", mergeStrategy: "squash", deleteBranchOnMerge: false,
           protection: { requiredChecks: ["check"], strict: false } },
    commands: { install: "", typecheck: $tc, test: "", build: "", dev: "", lint: null },
    review: { gate: "none", localReviewers: [] },
    deploy: { trigger: "none" },
    qa: {},
    rules: { docs: ["README.md"] }
  }'
}
# repo <dir> [typecheck] — a repo with the config, the init marker and a README, committed
repo() {
  git init -q -b main "$1"; mkdir "$1/.claude"
  fixture "${2-}" > "$1/.claude/autopilot.config.json"
  printf '{ "version": 1, "initializedAt": "2026-01-01T00:00:00Z" }\n' > "$1/.claude/autopilot.init.json"
  echo app > "$1/README"
  git -C "$1" add -A; git -C "$1" commit -q -m "chore: init"
}

scenario_load() {
  local R="$T/load" N="$T/load-none" C="$T/load/.claude/autopilot.config.json"
  repo "$R" true
  run in_dir "$R" "$CONFIG" load
  check "valid config + init marker → rc 0, the config byte for byte on stdout" printed_config "$R"
  run in_dir "$R/.claude" "$CONFIG" load
  check "the same from a subdirectory" printed_config "$R"
  run in_dir "$R" "$CONFIG" load --reconfigure
  check "--reconfigure → rc 3, a detected draft on stdout" bash -c "[ $RC = 3 ] && jq -e '.version == 1' '$T/out'"
  check "… 'current config kept' on stderr" fails_with 3 "current config kept at $C"

  cp "$C" "$T/load-good.json"
  printf '{ "commands": \n' > "$C"
  run in_dir "$R" "$CONFIG" load
  check "a config that isn't JSON → rc 2, 'invalid JSON at <path>' on stderr" fails_with 2 "invalid JSON at $C"
  check "… nothing on stdout: the broken text never reaches the agent" bash -c "[ ! -s '$T/out' ]"
  run in_dir "$R" "$CONFIG" ensure
  check "… ensure (/autopilot:init) → rc 2 too, nothing on stdout" bash -c "[ $RC = 2 ] && [ ! -s '$T/out' ] && grep -qF 'invalid JSON at $C' '$T/err'"
  run in_dir "$R" "$CONFIG" dump
  check "… dump → rc 2 too, nothing on stdout" bash -c "[ $RC = 2 ] && [ ! -s '$T/out' ] && grep -qF 'invalid JSON at $C' '$T/err'"
  run in_dir "$R" "$CONFIG" load --reconfigure
  check "… load --reconfigure → rc 3, a detected draft on stdout (the interview rewrites the file)" \
    bash -c "[ $RC = 3 ] && jq -e '.version == 1' '$T/out'"
  check "… the cause on stderr, the interview told to start from the draft" \
    fails_with 3 "current config is broken (invalid JSON at $C): start the interview from the detected draft"
  echo '[]' > "$C"
  run in_dir "$R" "$CONFIG" load
  check "a config that is [] → rc 2, not one JSON object" fails_with 2 "config at $C is not one JSON object"
  check "… nothing on stdout" bash -c "[ ! -s '$T/out' ]"
  cp "$T/load-good.json" "$C"
  if [ "$(id -u)" = 0 ]; then
    skip "a config it can't read, --reconfigure (root reads any file)"
  else
    chmod 000 "$C"
    run in_dir "$R" "$CONFIG" load --reconfigure
    check "a config it can't read: load --reconfigure → rc 2, fix its permissions (the interview couldn't rewrite it)" \
      fails_with 2 "cannot read config at $C: fix its permissions"
    check "… no draft on stdout, the config not called broken" bash -c "[ ! -s '$T/out' ] && ! grep -qF 'is broken' '$T/err'"
    run in_dir "$R" "$CONFIG" ensure --reconfigure
    check "… ensure --reconfigure (/autopilot:init --force) → rc 2 too, nothing on stdout" \
      bash -c "[ $RC = 2 ] && [ ! -s '$T/out' ] && grep -qF 'cannot read config at $C: fix its permissions' '$T/err'"
    run in_dir "$R" "$CONFIG" load
    check "… load without --reconfigure → rc 2, the same hint" fails_with 2 "cannot read config at $C: fix its permissions"
    chmod 644 "$C"
  fi

  git init -q -b main "$N"; mkdir "$N/.claude"; cp "$R/.claude/autopilot.init.json" "$N/.claude/"
  git -C "$N" add -A; git -C "$N" commit -q -m "chore: init"
  : > "$T/stubs.log"
  run in_dir "$N" "$CONFIG" load
  check "no config → rc 3, 'no config at' on stderr" fails_with 3 "no config at $N/.claude/autopilot.config.json"
  check "… a detected draft on stdout: tracker none, base main, conventional commits" \
    jq -e '.version == 1 and .tracker.type == "none" and .git.baseBranch == "main"
      and .git.commitStyle == "conventional" and .commands.typecheck == ""
      and (._note | startswith("AUTODETECTED DRAFT"))' "$T/out"
  check "… detect stayed offline: gh and curl hit the stubs" bash -c "grep -q '^gh repo view' '$T/stubs.log' && grep -q '^curl ' '$T/stubs.log'"

  rm "$R/.claude/autopilot.init.json"
  run in_dir "$R" "$CONFIG" load
  check "config without .claude/autopilot.init.json → rc 4, NOT_INITIALIZED on stderr" fails_with 4 NOT_INITIALIZED
  check "… nothing on stdout" bash -c "[ ! -s '$T/out' ]"
}

scenario_get() {
  local R="$T/get"
  repo "$R" true
  run in_dir "$R" "$CONFIG" get '.git.baseBranch'
  check "get '.git.baseBranch' → trunk" got trunk
  run in_dir "$R" "$CONFIG" get '.missing' default
  check "get '.missing' default → default" got default
  run in_dir "$R" "$CONFIG" get '.missing'
  check "get '.missing' → an empty line" got ""
  run in_dir "$R" "$CONFIG" get '.git.deleteBranchOnMerge' true
  check "get of a false value with a default → false (the default replaces only null or absent)" got false
  run in_dir "$R" "$CONFIG" get '.commands.lint' none
  check "get of a null value with a default → the default" got none
  run in_dir "$R" "$CONFIG" get '.git.protection.requiredChecks[0]'
  check "get '.git.protection.requiredChecks[0]' → check" got check
  run in_dir "$R" "$CONFIG" get '.git |||' default
  check "get with a broken filter → the default" got default
  run in_dir "$R" "$CONFIG" path
  check "path → <repo>/.claude/autopilot.config.json" got "$R/.claude/autopilot.config.json"
  run in_dir "$R" "$CONFIG" exists
  check "exists → rc 0" rc_is 0
  run in_dir "$R" "$CONFIG" dump
  check "dump → the config" printed_config "$R"

  local C="$R/.claude/autopilot.config.json"
  printf '{ "git": {\n<<<<<<< HEAD\n' > "$C"
  run in_dir "$R" "$CONFIG" get '.git.baseBranch' main
  check "a config that isn't JSON: get → rc 2, 'invalid JSON at <path>' on stderr" fails_with 2 "invalid JSON at $C"
  check "… not the default" bash -c "[ ! -s '$T/out' ]"
  : > "$C"
  run in_dir "$R" "$CONFIG" get '.git.baseBranch' main
  check "an empty config: get → rc 2, not one JSON object" fails_with 2 "config at $C is not one JSON object"
  echo '[]' > "$C"
  run in_dir "$R" "$CONFIG" get '.git.baseBranch' main
  check "a config that is []: get → rc 2, not one JSON object" fails_with 2 "config at $C is not one JSON object"
  if [ "$(id -u)" = 0 ]; then
    skip "a config it can't read (root reads any file)"
  else
    fixture true > "$C"; chmod 000 "$C"
    run in_dir "$R" "$CONFIG" get '.git.baseBranch' main
    check "a config it can't read: get → rc 2, cannot read" fails_with 2 "cannot read config at $C"
    chmod 644 "$C"
  fi

  rm "$R/.claude/autopilot.config.json"
  run in_dir "$R" "$CONFIG" exists
  check "no config: exists → rc 1" rc_is 1
  run in_dir "$R" "$CONFIG" get '.git.baseBranch' main
  check "no config: get → rc 2, 'no config at' on stderr" fails_with 2 "no config at"
}

scenario_validate() {
  local R="$T/validate" C="$T/validate/.claude/autopilot.config.json"
  repo "$R" true
  run in_dir "$R" "$CONFIG" validate
  check "the repo's valid config → rc 0, ok (structural)" bash -c "[ $RC = 0 ] && grep -q '^ok (structural): $C' '$T/out'"
  run in_dir "$R" "$CONFIG" validate "$C"
  check "the same file named as an argument → rc 0" rc_is 0
  printf '{ "version": 1,\n' > "$T/not-json.json"
  run in_dir "$R" "$CONFIG" validate "$T/not-json.json"
  check "not JSON → rc 2, invalid JSON" fails_with 2 "invalid JSON at $T/not-json.json"
  : > "$T/empty.json"
  run in_dir "$R" "$CONFIG" validate "$T/empty.json"
  check "an empty file → rc 2, not one JSON object (not 'version must be 1')" \
    fails_with 2 "config at $T/empty.json is not one JSON object"
  echo '[]' > "$T/array.json"
  run in_dir "$R" "$CONFIG" validate "$T/array.json"
  check "[] → rc 2, not one JSON object (not 'missing required top-level keys')" \
    fails_with 2 "config at $T/array.json is not one JSON object"
  jq 'del(.deploy, .qa)' "$C" > "$T/keys-missing.json"
  run in_dir "$R" "$CONFIG" validate "$T/keys-missing.json"
  check "deploy and qa missing → rc 2, both named" fails_with 2 "missing required top-level keys: deploy, qa"
  jq '.version = 2' "$C" > "$T/version-2.json"
  run in_dir "$R" "$CONFIG" validate "$T/version-2.json"
  check "version 2 → rc 2, version must be 1" fails_with 2 "version must be 1"
  run in_dir "$R" "$CONFIG" validate "$T/absent.json"
  check "a file that isn't there → rc 2, no config at <file>" fails_with 2 "no config at $T/absent.json"

  # .deploy.verify.timeoutSeconds: refused here, before the merge, as verify-deploy.sh would refuse it after
  local t range="autopilot-config: .deploy.verify.timeoutSeconds must be a whole number of seconds from 0 to 86400, got"
  for t in 86401 '"abc"' -5; do
    jq --argjson t "$t" '.deploy.verify.timeoutSeconds = $t' "$C" > "$T/timeout.json"
    run in_dir "$R" "$CONFIG" validate "$T/timeout.json"
    check "timeoutSeconds $t → rc 2, the key, the value and the range" fails_with 2 "$range '$(jq -r . <<<"$t")'"
  done
  # glibc's en_US.UTF-8 has bash's [0-9] match Arabic-Indic digits; C.UTF-8 doesn't, so it comes second
  local locales loc; locales=$(locale -a 2>/dev/null || true)
  loc=$(grep -m 1 -ixE 'en_US\.utf-?8' <<<"$locales" || grep -m 1 -ixE 'C\.utf-?8' <<<"$locales" || true)
  if [ -z "$loc" ]; then
    skip "timeoutSeconds in Arabic-Indic digits under a UTF-8 locale (neither en_US.UTF-8 nor C.UTF-8 here)"
  else
    jq '.deploy.verify.timeoutSeconds = "٣٠"' "$C" > "$T/timeout.json"
    run in_dir "$R" env LC_ALL="$loc" "$CONFIG" validate "$T/timeout.json"
    check "timeoutSeconds \"٣٠\" under LC_ALL=$loc → rc 2, the range named" fails_with 2 "$range '٣٠'"
  fi
  for t in absent null 0 86400 '"30"'; do
    if [ "$t" = absent ]; then cp "$C" "$T/timeout.json"
    else jq --argjson t "$t" '.deploy.verify.timeoutSeconds = $t' "$C" > "$T/timeout.json"; fi
    run in_dir "$R" "$CONFIG" validate "$T/timeout.json"
    check "timeoutSeconds $t → rc 0, ok (structural)" bash -c "[ $RC = 0 ] && grep -q '^ok (structural): $T/timeout.json' '$T/out'"
  done
  run in_dir "$R" "$CONFIG" timeout
  check "timeout, none set → 600" got 600
  jq '.deploy.verify.timeoutSeconds = "030"' "$C" > "$T/timeout.json"
  run in_dir "$R" "$CONFIG" timeout "$T/timeout.json"
  check "timeout \"030\" → 30, not octal" got 30
  # written as is: jq 1.7 prints 30.0 as written, which verify-deploy.sh's arithmetic would refuse
  jq '.deploy.verify.timeoutSeconds = "__T__"' "$C" | sed 's/"__T__"/30.0/' > "$T/timeout.json"
  run in_dir "$R" "$CONFIG" timeout "$T/timeout.json"
  check "timeout 30.0 → 30" got 30
  jq '.deploy.verify.timeoutSeconds = "__T__"' "$C" | sed 's/"__T__"/-0/' > "$T/timeout.json"
  run in_dir "$R" "$CONFIG" timeout "$T/timeout.json"
  check "timeout -0 → 0, digits only" got 0
}

scenario_autopilot-repo() {
  local A="$T/repo-a" B="$T/repo-b" E="$T/elsewhere"
  repo "$A" 'pwd >> "$TC_RUNS"'; repo "$B" 'pwd >> "$TC_RUNS"'; mkdir "$E"
  jq '.git.baseBranch = "b-branch"' "$A/.claude/autopilot.config.json" > "$B/.claude/autopilot.config.json"
  git -C "$B" commit -qam "chore: b's own base"
  run in_dir "$E" env AUTOPILOT_REPO="$A" "$CONFIG" load
  check "outside any repo: load → rc 0, <dir>'s config" printed_config "$A"
  run in_dir "$B" env AUTOPILOT_REPO="$A" "$CONFIG" get '.git.baseBranch'
  check "inside another repo: get reads <dir>'s config, not the cwd's" got trunk
  run in_dir "$B" env AUTOPILOT_REPO=../repo-a "$CONFIG" path
  check "a relative <dir> → path in <dir>" got "$A/.claude/autopilot.config.json"
  run in_dir "$E" env AUTOPILOT_REPO="$T/absent" "$CONFIG" get '.git.baseBranch'
  check "a <dir> that isn't there → rc 2" fails_with 2 "AUTOPILOT_REPO is not a directory"

  run in_dir "$B" env AUTOPILOT_REPO="$A" "$TYPECHECK"
  check "typecheck.sh inside another repo → <dir>'s command, run in <dir>" bash -c "[ $RC = 0 ] && [ \"\$(tail -n 1 '$TC_RUNS')\" = '$A' ]"
  check "… its cache in <dir>'s git dir, none in the cwd's" bash -c "[ -f '$A/.git/autopilot/typecheck-ok' ] && [ ! -e '$B/.git/autopilot' ]"
  run in_dir "$E" env AUTOPILOT_REPO="$A" "$TYPECHECK"
  check "typecheck.sh outside any repo → cached pass of <dir>'s tree" bash -c "[ $RC = 0 ] && grep -q '^typecheck: cached pass' '$T/out'"
  check "… <dir>'s command ran once, the cwd's never" bash -c "[ \"\$(grep -cxF '$A' '$TC_RUNS')\" = 1 ] && ! grep -qxF '$B' '$TC_RUNS'"
}

scenario_typecheck() {
  local S="$T/tc-skip" P="$T/tc-pass" F="$T/tc-fail"
  repo "$S" ""
  run in_dir "$S" "$TYPECHECK"
  check "empty .commands.typecheck → rc 0, skipped" bash -c "[ $RC = 0 ] && grep -q '^typecheck: skipped' '$T/out'"

  repo "$P" 'pwd >> "$TC_RUNS"'
  echo '*.log' > "$P/.gitignore"; git -C "$P" add .gitignore; git -C "$P" commit -q -m "chore: ignore logs"
  run in_dir "$P" "$TYPECHECK"
  check "a passing command → rc 0, typecheck: pass" bash -c "[ $RC = 0 ] && grep -qx 'typecheck: pass' '$T/out'"
  check "… ran once, in the repo root" ran "$P" 1
  run in_dir "$P" "$TYPECHECK"
  check "the same tree → rc 0, cached pass" bash -c "[ $RC = 0 ] && grep -q '^typecheck: cached pass' '$T/out'"
  check "… not run again" ran "$P" 1
  echo debug > "$P/debug.log"
  run in_dir "$P/.claude" "$TYPECHECK"
  check "a new .gitignored file, run from a subdirectory → cached pass" bash -c "[ $RC = 0 ] && grep -q '^typecheck: cached pass' '$T/out'"
  echo more >> "$P/README"
  run in_dir "$P" "$TYPECHECK"
  check "a tracked file changed → runs again, pass" bash -c "[ $RC = 0 ] && grep -qx 'typecheck: pass' '$T/out'"
  echo new > "$P/new.txt"
  run in_dir "$P" "$TYPECHECK"
  check "an untracked file added → runs again, pass" bash -c "[ $RC = 0 ] && grep -qx 'typecheck: pass' '$T/out'"
  check "… 3 runs so far" ran "$P" 3
  check "… the real index untouched: README unstaged, new.txt untracked" \
    bash -c "[ \"\$(git -C '$P' status --porcelain | tr '\n' ';')\" = ' M README;?? new.txt;' ]"
  run in_dir "$P" "$TYPECHECK" --force
  check "--force on a cached tree → runs again, pass" bash -c "[ $RC = 0 ] && grep -qx 'typecheck: pass' '$T/out'"
  check "… 4 runs" ran "$P" 4
  git -C "$P" add -A; git -C "$P" commit -q -m "feat: more"
  run in_dir "$P" "$TYPECHECK"
  check "the same tree committed → cached pass" bash -c "[ $RC = 0 ] && grep -q '^typecheck: cached pass' '$T/out'"

  repo "$F" 'pwd >> "$TC_RUNS"; exit 7'
  run in_dir "$F" "$TYPECHECK"
  check "a failing command → its exit code 7, no pass" bash -c "[ $RC = 7 ] && ! grep -q 'typecheck: .*pass' '$T/out'"
  run in_dir "$F" "$TYPECHECK"
  check "a failure isn't cached → runs again, 7 again" bash -c "[ $RC = 7 ] && [ \"\$(grep -cxF '$F' '$TC_RUNS')\" = 2 ]"

  printf '{ "commands": \n' > "$F/.claude/autopilot.config.json"
  run in_dir "$F" "$TYPECHECK"
  check "a config that isn't JSON → rc 2, the config named on stderr" fails_with 2 "invalid JSON at $F/.claude/autopilot.config.json"
  check "… not skipped, not run" bash -c "! grep -q '^typecheck:' '$T/out' && [ \"\$(grep -cxF '$F' '$TC_RUNS')\" = 2 ]"
}

# answer <code> [body] — the tracker's reply to detect's probe; `answer none`: curl fails, as offline
answer() {
  rm -rf "$T/curl"; [ "$1" != none ] || return 0
  mkdir "$T/curl"; printf '%s' "${2-}" > "$T/curl/body"; echo "$1" > "$T/curl/code"
}
probed() { [ "$(cat "$T/curl/url")" = "$1/api/projects" ]; }             # probed <tracker url>
sent() { [ "$(grep -v '^$' "$T/curl/headers")" = "$(printf '%s\n' "$@")" ]; }  # sent <header …>: those on stdin, no other
answered() { got "$1" && probed "$2"; }                                  # answered <backlog's output> <tracker url>
# scopes <project key> <local server> <user server> [project extras] — ~/.claude.json with the backlog
# MCP server in local scope (under <project key>) and user scope; "" leaves one out
scopes() {
  jq -n --arg p "$1" --argjson l "${2:-null}" --argjson u "${3:-null}" --argjson x "${4:-null}" '
    { projects: { ($p): ((if $l then { mcpServers: { backlog: $l } } else {} end) + ($x // {})) } }
    + (if $u then { mcpServers: { backlog: $u } } else {} end)' > "$HOME/.claude.json"
}
http_server() { jq -nc --arg url "$1" '{ type: "http", url: $url }'; }

scenario_detect() {
  local R="$T/detect" W="$T/detect-wt" US="$HOME/.claude/settings.json" L U H
  L=$(http_server https://local.example/mcp); U=$(http_server https://user.example/mcp)
  repo "$R" true; git -C "$R" worktree add -q -b wt "$W"; mkdir -p "$HOME/.claude"
  jq -n '{ mcpServers: { backlog: { type: "http", url: "https://repo.example/mcp" } } }' > "$R/.mcp.json"
  answer 200 '[{"key":"AS"}]'

  scopes "$R" "$L" "$U"; echo '{ "enabledMcpjsonServers": ["backlog"] }' > "$US"
  run in_dir "$R" "$CONFIG" backlog
  check "local scope, an approved .mcp.json, user scope → local scope's tracker, up AS" answered "up AS" https://local.example
  check "… asked for this repo's projects: repoPath=<repo>" bash -c "[ \"\$(cat '$T/curl/repoPath')\" = '$R' ]"
  scopes "$R" "" "$U"
  run in_dir "$R" "$CONFIG" backlog
  check "no local scope → the repo's .mcp.json, approved in the user's settings" answered "up AS" https://repo.example
  rm "$US"
  run in_dir "$R" "$CONFIG" backlog
  check "… not approved → user scope" answered "up AS" https://user.example
  scopes "$R" "" "$U" '{ "enabledMcpjsonServers": ["backlog"] }'
  run in_dir "$R" "$CONFIG" backlog
  check "… approved by the project's entry in ~/.claude.json → .mcp.json" answered "up AS" https://repo.example
  scopes "$R" "" "$U"; echo '{ "enableAllProjectMcpServers": true }' > "$R/.claude/settings.local.json"
  run in_dir "$R" "$CONFIG" backlog
  check "… approved by .claude/settings.local.json (enableAllProjectMcpServers) → .mcp.json" answered "up AS" https://repo.example
  mv "$R/.claude/settings.local.json" "$R/.claude/settings.json"
  run in_dir "$R" "$CONFIG" backlog
  check "… approved only by the repo's committed .claude/settings.json → user scope" answered "up AS" https://user.example
  rm "$R/.claude/settings.json"
  echo '{ "enabledMcpjsonServers": ["backlog"] }' > "$US"; echo '{ "disabledMcpjsonServers": ["backlog"] }' > "$R/.claude/settings.local.json"
  run in_dir "$R" "$CONFIG" backlog
  check "… approved by the user, rejected in settings.local.json → user scope" answered "up AS" https://user.example
  rm "$US" "$R/.claude/settings.local.json"
  scopes "$R" "$L" ""
  run in_dir "$W" "$CONFIG" backlog
  check "in a worktree, local scope under its main checkout → that tracker" answered "up AS" https://local.example
  check "… repoPath=<the main checkout>, which the tracker knows the repo by" bash -c "[ \"\$(cat '$T/curl/repoPath')\" = '$R' ]"
  rm "$HOME/.claude.json" "$R/.mcp.json"
  run in_dir "$R" "$CONFIG" backlog
  check "no backlog MCP server anywhere → the local tracker at 127.0.0.1:4400" answered "up AS" http://127.0.0.1:4400
  check "… no headers sent" sent

  H=$(jq -nc '{ type: "http", url: "${BACKLOG_TEST_URL:-https://fallback.example}/mcp", headers: {
    "Authorization": "Bearer ${BACKLOG_TEST_TOKEN}", "X-Backlog-Org": "${AUTOPILOT_TEST_ORG:-none}",
    "X-Home": "${HOME}", "X-Other": "${OTHER_TEST_SECRET:-dflt}", "X-Unset": "${BACKLOG_TEST_UNSET}",
    "X-Empty": "", "X-Crlf": "a\r\nX-Evil: 1" } }')
  scopes "$R" "$H" ""
  run in_dir "$R" env BACKLOG_TEST_TOKEN=tok-1 AUTOPILOT_TEST_ORG=acme OTHER_TEST_SECRET=leaked "$CONFIG" backlog
  check "\${BACKLOG_*:-default} unset in the url → the default" answered "up AS" https://fallback.example
  check "… headers: BACKLOG_*/AUTOPILOT_* expanded, other names as written or their default, CR/LF dropped" \
    sent "Authorization: Bearer tok-1" "X-Backlog-Org: acme" 'X-Home: ${HOME}' "X-Other: dflt" \
      'X-Unset: ${BACKLOG_TEST_UNSET}' "X-Empty;" "X-Crlf: aX-Evil: 1"
  run in_dir "$R" env BACKLOG_TEST_URL=https://set.example "$CONFIG" backlog
  check "\${BACKLOG_*} set in the url → its value" answered "up AS" https://set.example

  scopes "$R" "$(jq -nc '{ type: "http", url: "https://local.example/mcp", headers: { authorization: "Bearer old", "X-Backlog-Org": "acme" } }')" ""
  run in_dir "$R" "$CONFIG" backlog
  check "the server's own headers go to its tracker" sent "authorization: Bearer old" "X-Backlog-Org: acme"
  run in_dir "$R" env AUTOPILOT_BACKLOG_TOKEN=tok-env "$CONFIG" backlog
  check "AUTOPILOT_BACKLOG_TOKEN replaces its Authorization (any case), keeps the rest" \
    sent "X-Backlog-Org: acme" "Authorization: Bearer tok-env"
  check "… the token on stdin only, not in curl's argv" bash -c "! grep -q tok-env '$T/stubs.log'"
  run in_dir "$R" env AUTOPILOT_BACKLOG_URL=https://env.example/mcp/ AUTOPILOT_BACKLOG_TOKEN=tok-env "$CONFIG" backlog
  check "AUTOPILOT_BACKLOG_URL over the MCP server → that tracker, /mcp/ dropped" answered "up AS" https://env.example
  check "… the server's headers stay with its own tracker, the token goes" sent "Authorization: Bearer tok-env"

  scopes "$R" "$L" ""
  answer 200 $'[\n  { "key": "AS" },\n  { "key": "WEB" }\n]'
  run in_dir "$R" "$CONFIG" backlog
  check "200 with a body over several lines → up AS WEB" got "up AS WEB"
  answer 200 '[]'
  run in_dir "$R" "$CONFIG" backlog
  check "200, no project for this repo → up, no keys" got "up "
  answer 200 '<html>Sign in</html>'
  run in_dir "$R" "$CONFIG" backlog
  check "200 that isn't a JSON array → down <url> 200" got "down https://local.example 200"
  for code in 401 403; do
    answer "$code" '{"error":"unauthorized"}'
    run in_dir "$R" "$CONFIG" backlog
    check "$code → refused <url> $code" got "refused https://local.example $code"
  done
  for code in 302 500 000; do
    answer "$code" ''
    run in_dir "$R" "$CONFIG" backlog
    check "$code → down <url> $code" got "down https://local.example $code"
  done
  answer none
  run in_dir "$R" "$CONFIG" backlog
  check "curl fails with no output → down <url> 000" got "down https://local.example 000"
  scopes "$R" "$(http_server 'https://me:secret@hosted.example/mcp?token=t#top')" ""; answer 401 ''
  run in_dir "$R" "$CONFIG" backlog
  check "credentials, query and /mcp left out of the url it probes and prints" answered "refused https://hosted.example 401" https://hosted.example
  scopes "$R" '{ "command": "npx", "args": ["-y", "backlog-mcp"] }' ""; answer none
  run in_dir "$R" "$CONFIG" backlog
  check "a stdio server, nothing answers → unusable" got unusable
  answer 200 '[{"key":"AS"}]'
  run in_dir "$R" "$CONFIG" backlog
  check "… the local tracker answers → up AS from 127.0.0.1:4400" answered "up AS" http://127.0.0.1:4400
  rm "$HOME/.claude.json"; answer none
  run in_dir "$R" "$CONFIG" backlog
  check "no server, nothing answers → nothing printed" got ""

  scopes "$R" "$L" ""; answer 200 '[{"key":"AS"}]'
  run in_dir "$R" "$CONFIG" detect
  check "detect, up AS → tracker backlog, keyPrefix AS, the key in _note" jq -e '.tracker.type == "backlog"
    and .tracker.mcp == "mcp__backlog" and .tracker.keyPrefix == "AS" and (._note | contains("bound to this repo: AS —"))' "$T/out"
  answer 200 '[{"key":"AS"},{"key":"WEB"}]'
  run in_dir "$R" "$CONFIG" detect
  check "detect, up AS WEB → tracker backlog, keyPrefix left to init" jq -e '.tracker.type == "backlog"
    and .tracker.keyPrefix == "" and (._note | contains("bound to this repo: AS WEB —"))' "$T/out"
  answer 401 ''
  run in_dir "$R" "$CONFIG" detect
  check "detect, refused 401 → tracker backlog, no keyPrefix, why in _note" jq -e '.tracker.type == "backlog"
    and .tracker.keyPrefix == "" and (._note | contains("refused autodetect (HTTP 401)"))' "$T/out"
  answer 000 ''
  run in_dir "$R" "$CONFIG" detect
  check "detect, down 000 → tracker none, 'gave no answer' in _note" jq -e '.tracker.type == "none"
    and (._note | contains("configured at https://local.example") and contains("gave no answer"))' "$T/out"
  scopes "$R" '{ "command": "npx" }' ""; answer none
  run in_dir "$R" "$CONFIG" detect
  check "detect, unusable → tracker none, 'no http URL' in _note" jq -e '.tracker.type == "none"
    and (._note | contains("with no http URL detect can use"))' "$T/out"
  rm -rf "$T/curl" "$HOME/.claude.json" "$HOME/.claude"
}

echo "autopilot-config.sh and typecheck.sh under bash $(bash -c 'echo "$BASH_VERSION"')"
ALL="load get validate autopilot-repo typecheck detect"
for s in ${*:-$ALL}; do
  case " $ALL " in *" $s "*) ;; *) echo "unknown scenario: $s (have: $ALL)" >&2; exit 2;; esac
  echo "$s"
  "scenario_$s" || nok "$s stopped early (exit $?)"
done
[ -z "${KEEP:-}" ] || echo "(kept: $T)"
echo
if [ "$FAILS" = 0 ]; then echo "config: all checks passed"; else echo "config: $FAILS check(s) failed"; exit 1; fi
