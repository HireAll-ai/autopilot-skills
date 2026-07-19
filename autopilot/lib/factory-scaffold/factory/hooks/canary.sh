#!/usr/bin/env bash
# Post-merge canary: watch prod for a short window after deploy (gstack /canary
# in spirit). Polls FACTORY_PROD_URL, fails on consecutive errors so the run
# summary can recommend a revert. Exit 1 = canary failed (the graph routes this
# to the summary node, it never blocks the pipeline in a retry loop).
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true
source factory/hooks/lib-e2e.sh

: "${FACTORY_PROD_URL:?set FACTORY_PROD_URL per product}"

MINUTES="${FACTORY_CANARY_MINUTES:-5}"
INTERVAL="${FACTORY_CANARY_INTERVAL:-15}"
HEALTH_PATH="${FACTORY_CANARY_PATH:-/}"
MAX_CONSECUTIVE="${FACTORY_CANARY_MAX_CONSECUTIVE_FAILURES:-3}"
SLOW_SECONDS="${FACTORY_CANARY_SLOW_SECONDS:-5}"

URL="${FACTORY_PROD_URL%/}${HEALTH_PATH}"
ARTIFACTS_DIR="factory-artifacts/$(run_namespace)/canary"
mkdir -p "$ARTIFACTS_DIR"
REPORT="$ARTIFACTS_DIR/report.txt"
: > "$REPORT"

end=$(( $(date +%s) + MINUTES * 60 ))
total=0 fails=0 consec=0 slow=0
echo "Canary: $URL for ${MINUTES}m (interval ${INTERVAL}s, fail after ${MAX_CONSECUTIVE} consecutive errors)" | tee -a "$REPORT"

while [ "$(date +%s)" -lt "$end" ]; do
  total=$((total + 1))
  line=$(curl -o /dev/null -sS -m 10 -w '%{http_code} %{time_total}' "$URL" 2>/dev/null || echo "000 0")
  code=${line%% *}
  t=${line##* }
  case "$code" in
    2*|3*) consec=0 ;;
    *) fails=$((fails + 1)); consec=$((consec + 1)) ;;
  esac
  awk "BEGIN{exit !($t > $SLOW_SECONDS)}" && slow=$((slow + 1)) || true
  echo "$(date -u +%H:%M:%SZ) http=$code time=${t}s" >> "$REPORT"
  if [ "$consec" -ge "$MAX_CONSECUTIVE" ]; then
    {
      echo "=================================================="
      echo "CANARY FAILED: $consec consecutive errors on $URL"
      echo "Checks: $total, errors: $fails, slow(>${SLOW_SECONDS}s): $slow"
      echo "Report: $REPORT"
      echo "=================================================="
    } | tee -a "$REPORT"
    exit 1
  fi
  sleep "$INTERVAL"
done

{
  echo "=================================================="
  echo "CANARY HEALTHY: $URL"
  echo "Checks: $total, errors: $fails, slow(>${SLOW_SECONDS}s): $slow"
  echo "Report: $REPORT"
  echo "=================================================="
} | tee -a "$REPORT"
