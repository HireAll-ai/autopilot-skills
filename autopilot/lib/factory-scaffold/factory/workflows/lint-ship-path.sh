#!/usr/bin/env bash
# Guard against ship-path drift across lanes. The ship path is duplicated in
# every lane graph (fabro has no includes), so this checks the structural
# invariant instead: required nodes/edges present, in order, same hooks.
# Prompts MAY differ per lane (review focus etc.) — structure may not.
# Run after editing any factory/workflows/*.dot, alongside `fabro validate`.
set -euo pipefail
cd "$(dirname "$0")"

fail=0
err() { echo "FAIL [$1] $2"; fail=1; }

need() { # need <lane> <pattern> <description>
  grep -Eq "$2" "$1.dot" || err "$1" "$3"
}

# Every lane merges and watches prod afterwards.
for lane in express-lane iterate-lane feature-pipeline bugfix-express bugfix-deep; do
  [ -f "$lane.dot" ] || { err "$lane" "graph file missing"; continue; }
  need "$lane" 'script="\./factory/hooks/open-pr\.sh"'          "open_pr hook missing"
  need "$lane" 'script="\./factory/hooks/merge\.sh"'            "merge hook missing"
  need "$lane" 'script="\./factory/hooks/prod-e2e-video\.sh"'   "prod e2e/smoke hook missing"
  need "$lane" 'script="\./factory/hooks/canary\.sh"'           "canary hook missing"
  need "$lane" 'canary_gate.*Canary healthy'                    "canary_gate diamond missing"
  need "$lane" 'canary -> canary_gate'                          "prod -> canary -> canary_gate edge missing"
  need "$lane" 'canary_gate -> summary \[label="Healthy", condition="outcome=succeeded"\]' "canary healthy edge missing"
  need "$lane" 'summary -> exit'                                "summary -> exit missing"
done

# Full lanes: docs before PR, cross-review + fix loop before merge.
for lane in iterate-lane feature-pipeline bugfix-deep; do
  need "$lane" 'docs_update -> open_pr'                         "docs_update before open_pr missing"
  need "$lane" 'open_pr -> review'                              "open_pr -> review edge missing"
  need "$lane" 'fixes_gate -> merge.*context\.log contains CLEAN' "fixes_gate CLEAN edge missing"
  need "$lane" 'fixes_gate -> apply_fixes'                      "fixes_gate -> apply_fixes edge missing"
done

# QA + security are part of feature and iterate lanes.
for lane in iterate-lane feature-pipeline; do
  need "$lane" 'qa_explore'                                     "exploratory QA node missing"
  need "$lane" 'security_review'                                "security review (CSO) node missing"
  need "$lane" 'review -> security_review -> fixes_gate'        "review -> security_review -> fixes_gate chain missing"
done

# Merged-lane invariants: feature-quick is gone, feature-pipeline carries modes.
[ -f feature-quick.dot ] && err "feature-quick" "lane was merged into feature-pipeline (-I no_spec=true) — delete this file"
need feature-pipeline 'inputs\.no_spec'                         "no_spec input missing"
need feature-pipeline 'inputs\.auto'                            "auto input missing"
need feature-pipeline 'context\.log contains AUTO_APPROVED'     "auto_gate AUTO_APPROVED condition missing"

if [ "$fail" -eq 0 ]; then
  echo "ship-path OK across all lanes"
else
  exit 1
fi
