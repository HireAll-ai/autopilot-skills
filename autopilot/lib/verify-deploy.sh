#!/usr/bin/env bash
# verify-deploy.sh — /autoship Step 5.1: prove the merge is live, per `.deploy.verify`.
#
# Long-running by design (polls up to `.deploy.verify.timeoutSeconds`, then may watch runs), so the
# caller runs it in the BACKGROUND and is re-invoked when it exits — it must never sit in a
# foreground Bash call, which is capped at 10 minutes.
#
# Usage: [AUTOPILOT_REPO=<dir>] verify-deploy.sh <merge-sha>   # AUTOPILOT_REPO: the merged PR's checkout,
#                                                             # when it isn't the cwd's repo
# Exit:  0  verified — the running build is <merge-sha> or a later commit that contains it and
#                      doesn't revert it (build-id) / the deploy run(s) went green (github-run)
#        1  broken   — deploy run failed, or the build-id endpoint was unreachable the whole window
#                      → hard STOP + revert recipe
#        10 unverified — nothing confirmed it in time (old build still answering, no run observed,
#                      mode none), or the live build reverts it. NOT a failure: the ship landed,
#                      report it as UNVERIFIED.
#        12 build-id endpoint answers but the commit reads unknown/empty; the last response's
#                      restartedAt value (if .deploy.verify.restartedAtJq is set) is printed so the
#                      caller can compare it to the merge time.
#        2  usage / config error, named on stderr — no config, one it can't read or that isn't one
#                      JSON object, a timeoutSeconds that isn't a whole number of seconds from 0 to
#                      86400 (a day), among them
set -uo pipefail

SHA="${1:-}"; [ -n "$SHA" ] || { echo "usage: verify-deploy.sh <merge-sha>" >&2; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ -n "${AUTOPILOT_REPO:-}" ]; then   # config + `gh repo view` below follow the cwd
  cd -- "$AUTOPILOT_REPO" || exit 2; export AUTOPILOT_REPO="$PWD"
fi
cfg() { "$SCRIPT_DIR/autopilot-config.sh" get "$1" "${2-}"; }

# `get` inside $(…) loses its exit code: no config would read as mode none, a broken one as every
# default — both rc 10. So one `get` first, outside $(…): it fails on a config that is missing,
# unreadable or not one JSON object, and names the cause, passed on here under this script's name.
if ! ERR="$("$SCRIPT_DIR/autopilot-config.sh" get . 2>&1 >/dev/null)"; then
  echo "verify-deploy: ${ERR#autopilot-config: }" >&2; exit 2
fi

TRIGGER="$(cfg '.deploy.trigger' 'none')"
MODE="$(cfg '.deploy.verify.mode' '')"
if [ -z "$MODE" ]; then [ "$TRIGGER" = "github-action" ] && MODE="github-run" || MODE="none"; fi
# `autopilot-config.sh timeout` checks it — the same check `validate` runs, so a config that passed
# validation isn't refused here after the merge — and prints only whole seconds from 0 to 86400: bash
# arithmetic never sees "abc" (read as a variable, its $(…) run in a subscript like "PATH[$(cmd)]"),
# nor a number past a day that 64-bit arithmetic would wrap into a deadline in the past
if ! TIMEOUT="$("$SCRIPT_DIR/autopilot-config.sh" timeout 2>&1)"; then
  echo "verify-deploy: ${TIMEOUT#autopilot-config: }" >&2; exit 2
fi
DEADLINE=$(( $(date +%s) + $TIMEOUT ))
echo "verify-deploy: mode=$MODE sha=$SHA timeout=${TIMEOUT}s"

case "$MODE" in
  none)
    echo "UNVERIFIED: deploy.verify.mode is none — nothing can confirm the build"; exit 10 ;;

  build-id)
    URL="$(cfg '.deploy.verify.buildIdUrl')"; JQ="$(cfg '.deploy.verify.buildIdJq' '.commit')"
    RJQ="$(cfg '.deploy.verify.restartedAtJq')"
    [ -n "$URL" ] || { echo "verify-deploy: mode=build-id needs .deploy.verify.buildIdUrl" >&2; exit 2; }
    BASE="$(cfg '.git.baseBranch' 'main')"
    REACHED=""; LIVE=""; BODY=""; FETCHED=""
    # A builder that deploys every push builds a PR merged right after ours instead: a live commit
    # that has <merge-sha> in its history carries the merge too, unless it also reverts it. Only
    # commit ids are compared (git would resolve `HEAD` or `main` locally). <base> is fetched once
    # per live commit git doesn't know yet (again after a failed fetch); one it doesn't know even
    # then is not this build, never an error.
    HEX='^[0-9a-fA-F]{7,64}$'
    known() { GIT_NO_LAZY_FETCH=1 git cat-file -e "$1^{commit}" 2>/dev/null; }
    fetch_base() {   # at most 60 s: a remote that stalls mustn't hold the poll
      GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
        git fetch -q origin "$BASE" >/dev/null 2>&1 &
      local fp=$! wp rc
      ( sleep 60; kill "$fp" ) >/dev/null 2>&1 & wp=$!
      wait "$fp" 2>/dev/null; rc=$?
      kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
      return "$rc"
    }
    contains_merge() {
      [[ "$SHA" =~ $HEX && "$LIVE" =~ $HEX ]] || return 1
      if ! { known "$SHA" && known "$LIVE"; } && [ "$FETCHED" != "$LIVE" ]; then
        fetch_base && FETCHED="$LIVE"
      fi
      GIT_NO_LAZY_FETCH=1 git merge-base --is-ancestor "$SHA" "$LIVE" >/dev/null 2>&1
    }
    reverts_merge() {   # grep reads it all: with pipefail, `grep -q` would fail git log on SIGPIPE
      GIT_NO_LAZY_FETCH=1 git log --format=%B "$SHA..$LIVE" 2>/dev/null \
        | grep -iF "This reverts commit $SHA" >/dev/null
    }
    while :; do
      if BODY="$(curl -fsS --max-time 10 "$URL" 2>/dev/null)"; then
        REACHED=1
        LIVE="$(printf '%s' "$BODY" | jq -r "($JQ) // empty" 2>/dev/null || true)"
        if [ "$LIVE" = "$SHA" ] || { [ ${#LIVE} -ge 7 ] && [ "${SHA#"$LIVE"}" != "$SHA" ]; }; then
          echo "VERIFIED: $URL reports $LIVE"; exit 0
        fi
        if contains_merge; then
          if reverts_merge; then
            echo "UNVERIFIED: $URL reports $LIVE, which contains $SHA but also reverts it"; exit 10
          fi
          echo "VERIFIED: $URL reports $LIVE (contains $SHA)"; exit 0
        fi
      fi
      [ "$(date +%s)" -lt "$DEADLINE" ] || break
      sleep 15
    done
    [ -n "$REACHED" ] || { echo "BROKEN: $URL unreachable for the whole ${TIMEOUT}s window"; exit 1; }
    case "$LIVE" in
      ""|unknown|null)
        R=""; [ -n "$RJQ" ] && R="$(printf '%s' "$BODY" | jq -r "($RJQ) // empty" 2>/dev/null || true)"
        echo "COMMIT_UNKNOWN: $URL answers but the commit reads '${LIVE:-<empty>}'; restartedAt=${R:-<n/a>}"
        exit 12 ;;
    esac
    echo "UNVERIFIED: $URL still reports $LIVE (not $SHA or a commit that contains it) after ${TIMEOUT}s"; exit 10 ;;

  github-run)
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 2
    BASE="$(cfg '.git.baseBranch' 'main')"; WF="$(cfg '.deploy.verify.workflow')"
    # Match the configured deploy workflow by name or file; unset → every push run for the SHA.
    FILTER='.workflow_runs[] | select($wf == "" or .name == $wf or (.path | endswith("/" + $wf)))'
    list_runs() {
      gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=push&branch=$BASE&per_page=50" \
        | jq -r --arg wf "$WF" "$FILTER | \"\(.id)\t\(.name)\""
    }
    # list first, then check the deadline, as build-id does: timeoutSeconds 0 is "look once, don't wait"
    RUNS="$(list_runs 2>/dev/null || true)"
    while [ -z "$RUNS" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
      sleep 20; RUNS="$(list_runs 2>/dev/null || true)"
    done
    [ -n "$RUNS" ] || { echo "UNVERIFIED: no push run${WF:+ of '$WF'} observed for $SHA within ${TIMEOUT}s"; exit 10; }
    # Without a named workflow, sibling runs can register a little later — collect them once more.
    if [ -z "$WF" ]; then sleep 20; RUNS="$(list_runs 2>/dev/null || echo "$RUNS")"; fi
    FAILED=""
    while IFS=$'\t' read -r ID NAME; do
      [ -n "$ID" ] || continue
      echo "watching run $ID ($NAME)"
      gh run watch "$ID" --exit-status --interval 30 >/dev/null 2>&1 || FAILED="$FAILED $ID($NAME)"
    done <<<"$RUNS"
    [ -z "$FAILED" ] || { echo "BROKEN: run(s) failed:$FAILED"; exit 1; }
    echo "VERIFIED: push run(s) for $SHA green: $(echo "$RUNS" | cut -f2 | paste -sd, -)"; exit 0 ;;

  *) echo "verify-deploy: unknown deploy.verify.mode '$MODE'" >&2; exit 2 ;;
esac
