#!/usr/bin/env bash
# autopilot-config.sh — load / detect / validate the per-project autopilot config.
#
# The /autodev, /autoship and /autopilot commands are project-independent; every
# project-specific fact lives in .claude/autopilot.config.json (committed). This helper is
# how the command bodies read that file and how the first-run interview bootstraps it.
#
# Usage:
#   autopilot-config.sh path                 # print resolved config path (exists or not)
#   autopilot-config.sh exists               # exit 0 if config present, 1 if not
#   autopilot-config.sh dump                 # cat the config JSON
#   autopilot-config.sh get <jqfilter> [def] # print a value (raw); [def] if null/missing
#   autopilot-config.sh detect               # print an autodetected DRAFT config to stdout
#   autopilot-config.sh validate [file]      # validate a config against the schema
#   autopilot-config.sh ensure               # exists → dump; missing → detect + exit 3
#
# `ensure` is the Step-0 entry point: exit 0 means "loaded" (config dumped to stdout);
# exit 3 means "no config — a detected draft is on stdout; run the interview and write it".
set -euo pipefail

_die() { echo "autopilot-config: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || _die "jq is required but not installed"

# --- path resolution -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_PATH="${AUTOPILOT_CONFIG:-$REPO_ROOT/.claude/autopilot.config.json}"
SCHEMA_PATH="$SCRIPT_DIR/../schema/autopilot.config.schema.json"

# --- helpers ---------------------------------------------------------------------------
_cmd_path() { echo "$CONFIG_PATH"; }

_cmd_exists() { [ -f "$CONFIG_PATH" ]; }

_cmd_dump() { _cmd_exists || _die "no config at $CONFIG_PATH (run: autopilot-config.sh detect)"; cat "$CONFIG_PATH"; }

# get <jqfilter> [default] — raw output; [default] applies ONLY when the value is null/absent.
# A present value is returned verbatim, including false / 0 / "" — booleans MUST survive (a plain
# `// empty` would collapse false and null alike and let the default invert a configured boolean).
_cmd_get() {
  local filter="${1:?usage: get <jqfilter> [default]}"; local def="${2-}"
  _cmd_exists || _die "no config at $CONFIG_PATH"
  local sent="__AUTOPILOT_ABSENT__" out
  out="$(jq -r "try ($filter) catch null | if . == null then \"$sent\" else . end" "$CONFIG_PATH" 2>/dev/null || printf '%s' "$sent")"
  if [ "$out" = "$sent" ]; then printf '%s\n' "$def"; else printf '%s\n' "$out"; fi
}

# detect the package-manager and its script commands from lockfiles + package.json.
_detect_commands() {
  local pm="" run="" pkg="$REPO_ROOT/package.json"
  if   [ -f "$REPO_ROOT/pnpm-lock.yaml" ]; then pm=pnpm;  run="pnpm";
  elif [ -f "$REPO_ROOT/yarn.lock" ];      then pm=yarn;  run="yarn";
  elif [ -f "$REPO_ROOT/bun.lockb" ] || [ -f "$REPO_ROOT/bun.lock" ]; then pm=bun; run="bun run";
  elif [ -f "$REPO_ROOT/package-lock.json" ]; then pm=npm; run="npm run";
  fi
  if [ -z "$pm" ]; then echo '{}'; return; fi
  # Which scripts exist?
  local has_tc="" has_test="" has_build="" has_dev=""
  if [ -f "$pkg" ]; then
    has_tc="$(jq -r '(.scripts."type-check" // .scripts.typecheck) // empty' "$pkg" 2>/dev/null || true)"
    has_test="$(jq -r '.scripts.test // empty' "$pkg" 2>/dev/null || true)"
    has_build="$(jq -r '.scripts.build // empty' "$pkg" 2>/dev/null || true)"
    has_dev="$(jq -r '.scripts.dev // empty' "$pkg" 2>/dev/null || true)"
  fi
  local tc_script="type-check"
  if [ -f "$pkg" ] && [ -z "$(jq -r '.scripts."type-check" // empty' "$pkg" 2>/dev/null)" ] \
     && [ -n "$(jq -r '.scripts.typecheck // empty' "$pkg" 2>/dev/null)" ]; then tc_script="typecheck"; fi
  local install_cmd="$run install"
  [ "$pm" = "npm" ] && install_cmd="npm ci"
  [ "$pm" = "pnpm" ] && install_cmd="pnpm install --frozen-lockfile"
  [ "$pm" = "yarn" ] && install_cmd="yarn install --frozen-lockfile"
  [ "$pm" = "bun" ] && install_cmd="bun install"   # NOT "bun run install" (that runs a package script)
  jq -n --arg run "$run" --arg install "$install_cmd" --arg tc "$tc_script" \
        --arg test "$has_test" --arg build "$has_build" --arg dev "$has_dev" '
    {
      install: $install,
      typecheck: (if $tc != "" then "\($run) \($tc)" else "" end),
      test:  (if $test  != "" then "\($run) test"  else "" end),
      build: (if $build != "" then "\($run) build" else "" end),
      dev:   (if $dev   != "" then "\($run) dev"   else "" end),
      testFilter: (if $run == "pnpm" then "pnpm --filter {pkg} test" else "" end),
      lint: null
    }'
}

# detect base branch + protection via gh (best effort; empty object if gh unavailable).
_detect_git() {
  local base="" repo=""
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  # prefer an existing 'develop' branch (team convention), else the repo default branch.
  if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
    base="develop"
  else
    base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)"
  fi
  local prot='{}'
  if [ -n "$repo" ]; then
    prot="$(gh api "repos/$repo/branches/$base/protection" --jq '{
      requiredChecks: [ (.required_status_checks.checks // [])[].context ],
      strict: (.required_status_checks.strict // false),
      requireThreadResolution: (.required_conversation_resolution.enabled // false),
      requiredApprovals: (.required_pull_request_reviews.required_approving_review_count // 0),
      adminBypassAllowed: ((.enforce_admins.enabled // true) | not)
    }' 2>/dev/null || echo '{}')"
  fi
  jq -n --arg base "$base" --argjson prot "$prot" '
    {
      baseBranch: $base,
      branchPattern: "{key}-{slug}",
      mergeStrategy: "squash",
      deleteBranchOnMerge: true,
      protection: (if ($prot|length)>0 then $prot else
        { requiredChecks: [], strict: false, requireThreadResolution: false, requiredApprovals: 0, adminBypassAllowed: false } end)
    }'
}

# detect ticket key prefix from recent commit subjects (e.g. ABC-123 → ABC).
_detect_key_prefix() {
  git -C "$REPO_ROOT" log --oneline -50 --format='%s' 2>/dev/null \
    | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+' | sed -E 's/-[0-9]+$//' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

# detect a health/deploy URL from repo docs + CI (best effort).
_detect_health_url() {
  { grep -rhoE 'https?://[^ )"'"'"']+/(api/)?health' \
      "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/README.md" "$REPO_ROOT/.github/workflows/" 2>/dev/null || true; } \
    | head -1
}

_cmd_detect() {
  local commands git_block key_prefix health
  commands="$(_detect_commands)"
  git_block="$(_detect_git)"
  key_prefix="$(_detect_key_prefix || true)"
  health="$(_detect_health_url || true)"
  jq -n \
    --argjson commands "$commands" \
    --argjson git "$git_block" \
    --arg keyPrefix "${key_prefix:-}" \
    --arg health "${health:-}" '
    {
      version: 1,
      tracker: {
        type: "none",
        mcp: "",
        keyPrefix: $keyPrefix,
        keyRequired: ($keyPrefix != ""),
        shipStatus: "",
        shipStatusVia: []
      },
      git: $git,
      commands: (if ($commands|length)>0 then $commands else
        { install:"", typecheck:"", test:"", testFilter:"", build:"", dev:"", lint:null } end),
      review: { gate: "none", localReviewers: [] },
      deploy: (if $health != "" then
        { trigger:"merge-to-base", autoDeploys:true, healthcheck:$health, urls:{}, docsRef:"" }
        else { trigger:"none" } end),
      qa: {
        browseSkill: "/browse", qaSkill: "/qa", qaOnlySkill: "/qa-only",
        video: { enabled:false, format:"mp4", surface:"context", dir:".context/video", maxSeconds:90 }
      },
      rules: {
        docs: (["CLAUDE.md","AGENTS.md"] | map(select(test("^/")|not))),
        planDir: "docs/plans",
        prTemplate: ".github/pull_request_template.md"
      },
      _note: "AUTODETECTED DRAFT — confirm/fill tracker (type,mcp,shipStatus), review.gate, and deploy.urls with the developer, then write to .claude/autopilot.config.json and git add it."
    }'
}

# validate a config file against the schema. Prefers ajv (node) if resolvable; else does
# a jq-based structural check of the required top-level keys + version.
_cmd_validate() {
  local file="${1:-$CONFIG_PATH}"
  [ -f "$file" ] || _die "no such config: $file"
  jq empty "$file" 2>/dev/null || _die "invalid JSON: $file"
  if command -v npx >/dev/null 2>&1 && npx --no-install ajv --help >/dev/null 2>&1; then
    # ajv is present — honor its verdict (a non-zero exit is a real failure, not a fall-through).
    if npx --no-install ajv validate -s "$SCHEMA_PATH" -d "$file"; then return 0; else _die "schema validation failed: $file"; fi
  fi
  # Fallback: required keys + version presence (schema is the full contract; this is a smoke check).
  local missing
  missing="$(jq -r '
    ["version","tracker","git","commands","review","deploy","qa","rules"]
    - (keys) | join(", ")' "$file")"
  [ -z "$missing" ] || _die "missing required top-level keys: $missing"
  [ "$(jq -r '.version' "$file")" = "1" ] || _die "version must be 1"
  echo "ok (structural): $file — install 'ajv-cli' for full schema validation"
}

_cmd_ensure() {
  if _cmd_exists; then _cmd_dump; exit 0; fi
  echo "autopilot-config: no config at $CONFIG_PATH — detected draft follows on stdout" >&2
  _cmd_detect
  exit 3
}

# --- dispatch --------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  path)     _cmd_path ;;
  exists)   _cmd_exists ;;
  dump)     _cmd_dump ;;
  get)      _cmd_get "$@" ;;
  detect)   _cmd_detect ;;
  validate) _cmd_validate "$@" ;;
  ensure)   _cmd_ensure ;;
  *) echo "usage: autopilot-config.sh {path|exists|dump|get <jqfilter> [def]|detect|validate [file]|ensure}" >&2; exit 2 ;;
esac
