#!/usr/bin/env bash
# verify-deploy.sh — /autoship Step 5.1: prove the merge is live, per `.deploy.verify`.
#
# Long-running by design (polls up to `.deploy.verify.timeoutSeconds`, then may watch runs), so the
# caller runs it in the BACKGROUND and is re-invoked when it exits — it must never sit in a
# foreground Bash call, which is capped at 10 minutes.
#
# Usage: verify-deploy.sh <merge-sha>
# Exit:  0  verified — the running build is <merge-sha> (build-id) / the deploy run(s) went green (github-run)
#        1  broken   — deploy run failed, or the build-id endpoint was unreachable the whole window
#                      → hard STOP + revert recipe
#        10 unverified — nothing confirmed it in time (old build still answering, no run observed,
#                      mode none). NOT a failure: the ship landed, report it as UNVERIFIED.
#        12 build-id endpoint answers but the commit reads unknown/empty; the last response's
#                      restartedAt value (if .deploy.verify.restartedAtJq is set) is printed so the
#                      caller can compare it to the merge time.
#        2  usage / config error
set -uo pipefail

SHA="${1:-}"; [ -n "$SHA" ] || { echo "usage: verify-deploy.sh <merge-sha>" >&2; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cfg() { "$SCRIPT_DIR/autopilot-config.sh" get "$1" "${2-}"; }

TRIGGER="$(cfg '.deploy.trigger' 'none')"
MODE="$(cfg '.deploy.verify.mode' '')"
if [ -z "$MODE" ]; then [ "$TRIGGER" = "github-action" ] && MODE="github-run" || MODE="none"; fi
TIMEOUT="$(cfg '.deploy.verify.timeoutSeconds' '600')"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
echo "verify-deploy: mode=$MODE sha=$SHA timeout=${TIMEOUT}s"

case "$MODE" in
  none)
    echo "UNVERIFIED: deploy.verify.mode is none — nothing can confirm the build"; exit 10 ;;

  build-id)
    URL="$(cfg '.deploy.verify.buildIdUrl')"; JQ="$(cfg '.deploy.verify.buildIdJq' '.commit')"
    RJQ="$(cfg '.deploy.verify.restartedAtJq')"
    [ -n "$URL" ] || { echo "verify-deploy: mode=build-id needs .deploy.verify.buildIdUrl" >&2; exit 2; }
    REACHED=""; LIVE=""; BODY=""
    while :; do
      if BODY="$(curl -fsS --max-time 10 "$URL" 2>/dev/null)"; then
        REACHED=1
        LIVE="$(printf '%s' "$BODY" | jq -r "($JQ) // empty" 2>/dev/null || true)"
        if [ "$LIVE" = "$SHA" ] || { [ ${#LIVE} -ge 7 ] && [ "${SHA#"$LIVE"}" != "$SHA" ]; }; then
          echo "VERIFIED: $URL reports $LIVE"; exit 0
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
    echo "UNVERIFIED: $URL still reports $LIVE (not $SHA) after ${TIMEOUT}s"; exit 10 ;;

  github-run)
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 2
    BASE="$(cfg '.git.baseBranch' 'main')"; WF="$(cfg '.deploy.verify.workflow')"
    # Match the configured deploy workflow by name or file; unset → every push run for the SHA.
    FILTER='.workflow_runs[] | select($wf == "" or .name == $wf or (.path | endswith("/" + $wf)))'
    list_runs() {
      gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=push&branch=$BASE&per_page=50" \
        | jq -r --arg wf "$WF" "$FILTER | \"\(.id)\t\(.name)\""
    }
    RUNS=""
    while [ -z "$RUNS" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
      RUNS="$(list_runs 2>/dev/null || true)"; [ -n "$RUNS" ] || sleep 20
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
