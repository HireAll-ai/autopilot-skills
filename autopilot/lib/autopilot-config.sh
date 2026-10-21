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
#   autopilot-config.sh get <jqfilter> [def] # print a value (raw); [def] if null/missing; rc 2 if the config is missing or broken
#   autopilot-config.sh detect               # print an autodetected DRAFT config to stdout
#   autopilot-config.sh backlog              # probe the backlog tracker: up <keys> | refused <url> <code> | down <url> <code> | unusable
#   autopilot-config.sh validate [file]      # validate a config against the schema
#   autopilot-config.sh ensure [--reconfigure]  # exists → dump; missing (or --reconfigure) → detect + exit 3
#   autopilot-config.sh load [--reconfigure]    # init marker check (exit 4 if missing), then ensure
#
# `load` is the Step-0 entry point of /autodev, /autoship, /autopilot: one call, everything on stdout
# so the agent reads the config ONCE into context. exit 0 = loaded (config on stdout); exit 3 = no
# config (or --reconfigure) — a detected draft is on stdout, run the interview and write it;
# exit 4 = repo not initialized (run /autopilot:init); exit 2 = hard error (stderr).
# `ensure` is the same minus the marker check (used by /autopilot:init itself).
#
# AUTOPILOT_REPO=<dir> runs any subcommand against the checkout at <dir> instead of the cwd — how
# /autoship loads the config of a PR it ships in another repo.
set -euo pipefail

_die() { echo "autopilot-config: $*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || _die "jq is required but not installed"

# --- path resolution -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
[ -z "${AUTOPILOT_REPO:-}" ] || cd -- "$AUTOPILOT_REPO" 2>/dev/null || _die "AUTOPILOT_REPO is not a directory: $AUTOPILOT_REPO"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG_PATH="${AUTOPILOT_CONFIG:-$REPO_ROOT/.claude/autopilot.config.json}"
INIT_MARKER="$REPO_ROOT/.claude/autopilot.init.json"
SCHEMA_PATH="$SCRIPT_DIR/../schema/autopilot.config.schema.json"

# --- helpers ---------------------------------------------------------------------------
_cmd_path() { echo "$CONFIG_PATH"; }

_cmd_exists() { [ -f "$CONFIG_PATH" ]; }

_cmd_dump() { _cmd_exists || _die "no config at $CONFIG_PATH (run: autopilot-config.sh detect)"; cat "$CONFIG_PATH"; }

# the config is there and holds exactly one JSON object, else rc 2 naming the cause. Slurped: `jq
# empty`, and jq 1.6's `-e` on its own, pass an empty file.
_check_config() {
  _cmd_exists || _die "no config at $CONFIG_PATH"
  [ -r "$CONFIG_PATH" ] || _die "cannot read config at $CONFIG_PATH"
  jq -es 'map(type) == ["object"]' "$CONFIG_PATH" >/dev/null 2>&1 && return 0
  jq empty "$CONFIG_PATH" >/dev/null 2>&1 || _die "invalid JSON at $CONFIG_PATH"
  _die "config at $CONFIG_PATH is not one JSON object"
}

# get <jqfilter> [default] — raw output; [default] applies ONLY when the value is null/absent.
# A present value is returned verbatim, including false / 0 / "" — booleans MUST survive (a plain
# `// empty` would collapse false and null alike and let the default invert a configured boolean).
# A config that is missing or broken fails (rc 2) rather than read as every default; a broken
# filter still reads as absent.
_cmd_get() {
  local filter="${1:?usage: get <jqfilter> [default]}"; local def="${2-}"
  _check_config
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
  local prot='{}' out
  # An unprotected branch is a 404 whose error body gh still prints to stdout — keep the output
  # only when the call succeeded, or the error JSON breaks the --argjson below.
  if [ -n "$repo" ] && out="$(gh api "repos/$repo/branches/$base/protection" --jq '{
      requiredChecks: [ (.required_status_checks.checks // [])[].context ],
      strict: (.required_status_checks.strict // false),
      requireThreadResolution: (.required_conversation_resolution.enabled // false),
      requiredApprovals: (.required_pull_request_reviews.required_approving_review_count // 0),
      adminBypassAllowed: ((.enforce_admins.enabled // true) | not)
    }' 2>/dev/null)"; then
    prot="$out"
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

# detect the commit style from recent subjects: conventional when at least half of them parse as
# Conventional Commits, else key-prefix (the default — it is what the commands did before the knob).
_detect_commit_style() {
  local total conv
  total="$(git -C "$REPO_ROOT" log --no-merges -50 --format='%s' 2>/dev/null | wc -l | tr -d ' ')"
  conv="$(git -C "$REPO_ROOT" log --no-merges -50 --format='%s' 2>/dev/null \
    | grep -cE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]*\))?!?: ' || true)"
  if [ "${total:-0}" -gt 0 ] && [ $(( conv * 2 )) -ge "$total" ]; then echo conventional; else echo key-prefix; fi
}

# detect a deploy workflow file under .github/workflows (best effort; first *deploy* file).
_detect_deploy_workflow() {
  ls "$REPO_ROOT"/.github/workflows/*deploy*.y*ml 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null || true
}

# detect a health/deploy URL from repo docs + CI (best effort).
_detect_health_url() {
  { grep -rhoE 'https?://[^ )"'"'"']+/(api/)?health' \
      "$REPO_ROOT/CLAUDE.md" "$REPO_ROOT/README.md" "$REPO_ROOT/.github/workflows/" 2>/dev/null || true; } \
    | head -1
}

# is the repo's .mcp.json `backlog` server approved on this machine? Only the operator's own word
# counts — enabledMcpjsonServers / enableAllProjectMcpServers in the user's settings, the repo's
# settings.local.json (not committed) or the project's entry in ~/.claude.json; a rejection
# (disabledMcpjsonServers) anywhere wins. Unlike Claude Code in a trusted folder, the repo's committed
# settings.json can't approve the repo's own server here: a cloned repo would point detect anywhere.
_mcpjson_approved() {
  local root="${1-}" config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" f
  local user="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" mine="$REPO_ROOT/.claude/settings.local.json"
  local named='if type == "string" then [.] elif type == "array" then . else [] end | any(. == "backlog")'
  local rejects="(.disabledMcpjsonServers | $named)"
  local approves="(.enableAllProjectMcpServers == true) or (.enabledMcpjsonServers | $named)"
  local project='(.projects[$a] // .projects[$b] // {})'
  for f in "$user" "$mine" "$REPO_ROOT/.claude/settings.json"; do
    if [ -f "$f" ] && jq -e "$rejects" "$f" >/dev/null 2>&1; then return 1; fi
  done
  if [ -f "$config" ] && jq -e --arg a "$REPO_ROOT" --arg b "$root" "$project | $rejects" "$config" >/dev/null 2>&1; then return 1; fi
  for f in "$user" "$mine"; do
    if [ -f "$f" ] && jq -e "$approves" "$f" >/dev/null 2>&1; then return 0; fi
  done
  [ -f "$config" ] && jq -e --arg a "$REPO_ROOT" --arg b "$root" "$project | $approves" "$config" >/dev/null 2>&1
}

# the operator's backlog MCP server as Claude Code resolves it: the server named `backlog` (the name
# /autopilot:init registers) from local scope (this project in ~/.claude.json — the worktree or its main
# checkout <root>), else the repo's .mcp.json once approved (above), else user scope. Prints
# {url, headers}; url is null when the server has none detect can use (stdio, a proxy command).
# ${VAR} / ${VAR:-default} expand for BACKLOG_* and AUTOPILOT_* names only: Claude Code keeps other
# credentials from remote servers by lists of its own, so any other name takes its default or stays
# as written, as an unset one does in Claude Code.
_backlog_mcp() {
  local root="${1-}" config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" server=""
  if [ -f "$config" ]; then
    server="$(jq -c --arg a "$REPO_ROOT" --arg b "$root" \
      '.projects[$a].mcpServers.backlog // .projects[$b].mcpServers.backlog // empty' "$config" 2>/dev/null || true)"
  fi
  if [ -z "$server" ] && [ -f "$REPO_ROOT/.mcp.json" ] && _mcpjson_approved "$root"; then
    server="$(jq -c '.mcpServers.backlog // empty' "$REPO_ROOT/.mcp.json" 2>/dev/null || true)"
  fi
  if [ -z "$server" ] && [ -f "$config" ]; then
    server="$(jq -c '.mcpServers.backlog // empty' "$config" 2>/dev/null || true)"
  fi
  [ -n "$server" ] || return 0
  printf '%s' "$server" | jq -c '
    def expand: gsub("\\$\\{(?<n>[A-Za-z_][A-Za-z0-9_]*)(?<d>:-[^}]*)?\\}";
      . as $m
      | if ($m.n | test("^(BACKLOG|AUTOPILOT)_")) and ($ENV | has($m.n)) then $ENV[$m.n]
        elif $m.d != null then $m.d[2:]
        else "${\($m.n)}" end);
    def clean: gsub("[\r\n]"; "");
    objects
    | { url: (if (.url | type) == "string" then .url | expand else null end),
        headers: ((.headers | objects) // {} | with_entries(.key |= clean | .value |= (tostring | expand | clean)))
      }' 2>/dev/null || true
}

# detect the backlog tracker (best effort, 5s timeout) where the operator's Claude Code reaches it:
# AUTOPILOT_BACKLOG_URL, else the url of the `backlog` MCP server, with its headers (a hosted tracker
# wants its token; AUTOPILOT_BACKLOG_TOKEN replaces the one there), else a local tracker at
# http://127.0.0.1:4400. Prints:
#   up <keys>             it answered: the keys of the projects bound to this repo (a monorepo can have several)
#   refused <url> <code>  it answered 401 (no token for it, or a wrong one) or 403 (no access, or a host it doesn't answer on)
#   down <url> <code>     the tracker configured above gave no answer (000), or not as the tracker
#   unusable              a backlog MCP server is registered with no url detect can use, and nothing else answered
# and nothing when none is configured and no local one runs. The tracker knows a repo by its main
# checkout, the root Constructor workspaces are worktrees of.
_detect_backlog() {
  local root mcp mcp_url="" url configured="" headers="" out code
  # the tracker's address: no credentials, query or /mcp in it — it is printed into the draft
  local base='sub("[?#].*$"; "") | sub("^(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@"; "\(.s)") | sub("/+$"; "") | sub("/mcp$"; "")'
  root="$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || true
  [ -n "$root" ] && command -v curl >/dev/null 2>&1 || return 0
  mcp="$(_backlog_mcp "$root")"
  [ -z "$mcp" ] || mcp_url="$(printf '%s' "$mcp" | jq -r ".url // empty | $base")"
  if [ -n "${AUTOPILOT_BACKLOG_URL:-}" ]; then url="$(printf '%s' "$AUTOPILOT_BACKLOG_URL" | jq -Rr "$base")"; configured=1
  elif [ -n "$mcp_url" ]; then url="$mcp_url"; configured=1
  else url="http://127.0.0.1:4400"; fi
  # The MCP server's headers go along only to its own tracker; the token from the environment, read
  # by jq itself, replaces its Authorization and keeps the rest (X-Backlog-Org picks the organization).
  if [ -n "$mcp_url" ] && [ "$mcp_url" = "$url" ]; then
    headers="$(printf '%s' "$mcp" | jq -r '($ENV.AUTOPILOT_BACKLOG_TOKEN // "") as $t | .headers | to_entries[]
      | select($t == "" or (.key | ascii_downcase) != "authorization")
      | if .value == "" then "\(.key);" else "\(.key): \(.value)" end')"   # curl drops "Key:", sends "Key;" empty
  fi
  [ -z "${AUTOPILOT_BACKLOG_TOKEN:-}" ] || headers="$headers"$'\n'"Authorization: Bearer $AUTOPILOT_BACKLOG_TOKEN"
  # Headers reach curl on stdin, one per line — in argv `ps` would show the token. -q: no ~/.curlrc.
  out="$(printf '%s\n' "$headers" | curl -q -sS --max-time 5 -G -H @- -w '\n%{http_code}' \
      "$url/api/projects" --data-urlencode "repoPath=$root" 2>/dev/null)" || true
  code="${out##*$'\n'}"
  case "$code" in
    2??)
      if out="$(printf '%s' "${out%$'\n'*}" | jq -er 'select(type == "array") | map(.key) | join(" ")' 2>/dev/null)"; then
        printf 'up %s' "$out"; return 0
      fi ;;
    401|403) printf 'refused %s %s' "$url" "$code"; return 0 ;;
  esac
  if [ -n "$configured" ]; then printf 'down %s %s' "$url" "${code:-000}"
  elif [ -n "$mcp" ]; then printf 'unusable'
  fi
}

_cmd_detect() {
  local commands git_block key_prefix health workflow backlog
  commands="$(_detect_commands)"
  git_block="$(_detect_git | jq --arg cs "$(_detect_commit_style)" '.commitStyle = $cs')"
  key_prefix="$(_detect_key_prefix || true)"
  health="$(_detect_health_url || true)"
  workflow="$(_detect_deploy_workflow)"
  backlog="$(_detect_backlog)"
  jq -n \
    --argjson commands "$commands" \
    --argjson git "$git_block" \
    --arg keyPrefix "${key_prefix:-}" \
    --arg health "${health:-}" \
    --arg workflow "${workflow:-}" \
    --arg backlog "${backlog:-}" '
    {
      version: 1,
      tracker: (($backlog | split(" ") | map(select(. != ""))) as $w |
        if $w[0] == "up" or $w[0] == "refused" then
        # one bound project: its key is the default; several, none or unknown: init Step 3 settles it.
        { type: "backlog", mcp: "mcp__backlog",
          keyPrefix: (if $w[0] == "up" and ($w | length) == 2 then $w[1] else "" end),
          keyRequired: false, autoCreateIssue: false, shipStatus: "done", shipStatusVia: [], followUps: "ask" }
        else {
        type: "none",
        mcp: "",
        keyPrefix: $keyPrefix,
        keyRequired: ($keyPrefix != ""),
        autoCreateIssue: false,
        shipStatus: "",
        shipStatusVia: [],
        followUps: "ask"
      } end),
      git: $git,
      commands: (if ($commands|length)>0 then $commands else
        { install:"", typecheck:"", test:"", testFilter:"", build:"", dev:"", lint:null } end),
      review: { gate: "none", localReviewers: [] },
      deploy: (if $workflow != "" then
        { trigger:"github-action", autoDeploys:true, healthcheck:$health, urls:{}, docsRef:"",
          verify:{ mode:"github-run", workflow:$workflow } }
        elif $health != "" then
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
      _note: ("AUTODETECTED DRAFT — confirm/fill tracker (type,mcp,shipStatus), review.gate, deploy.urls and deploy.verify with the developer, then write to .claude/autopilot.config.json and git add it."
        + (($backlog | split(" ") | map(select(. != ""))) as $w |
          if $w[0] == "up" then
            ($w[1:] | join(" ")) as $k | if $k != "" then " Backlog projects bound to this repo: \($k) — pick the default one for keyPrefix." else " The backlog tracker runs but has no project for this repo yet — /autopilot:init Step 3 binds or creates them." end
          elif $w[0] == "refused" then
            " The backlog tracker at \($w[1]) refused autodetect (HTTP \($w[2])): "
            + (if $w[2] == "403" then "no access for that token, or a host it does not answer on (a hosted tracker answers only on its public URL)"
               else "no token for it, or a wrong one — AUTOPILOT_BACKLOG_TOKEN when set, else the Authorization header of the backlog MCP server (one signed in with OAuth keeps its token to Claude Code; a ${VAR} there expands only for BACKLOG_* and AUTOPILOT_* names)" end)
            + ". Its projects are unknown here — /autopilot:init Step 3 binds them through the MCP tools."
          elif $w[0] == "down" then
            " A backlog tracker is configured at \($w[1]) (the backlog MCP server, or AUTOPILOT_BACKLOG_URL) but "
            + (if $w[2] == "000" then "gave no answer" elif ($w[2] | startswith("3")) then "redirects (HTTP \($w[2])) — register the URL it redirects to" else "answered HTTP \($w[2]), not as the tracker" end)
            + ", so tracker is none — check that it runs and its URL, then detect again."
          elif $w[0] == "unusable" then
            " A backlog MCP server is registered, but with no http URL detect can use (stdio, a proxy command), so tracker is none — set AUTOPILOT_BACKLOG_URL and AUTOPILOT_BACKLOG_TOKEN, then detect again."
          else "" end))
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
  if [ "${1-}" = "--reconfigure" ]; then
    _cmd_exists && echo "autopilot-config: --reconfigure — current config kept at $CONFIG_PATH (start the interview from its values); detected draft follows on stdout" >&2
    _cmd_detect; exit 3
  fi
  if _cmd_exists; then _cmd_dump; exit 0; fi
  echo "autopilot-config: no config at $CONFIG_PATH — detected draft follows on stdout" >&2
  _cmd_detect
  exit 3
}

_cmd_load() {
  if [ ! -f "$INIT_MARKER" ]; then
    echo "NOT_INITIALIZED: no $INIT_MARKER — run /autopilot:init first" >&2
    exit 4
  fi
  _cmd_ensure "$@"
}

# --- dispatch --------------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  path)     _cmd_path ;;
  exists)   _cmd_exists ;;
  dump)     _cmd_dump ;;
  get)      _cmd_get "$@" ;;
  detect)   _cmd_detect ;;
  backlog)  _detect_backlog; echo ;;
  validate) _cmd_validate "$@" ;;
  ensure)   _cmd_ensure "$@" ;;
  load)     _cmd_load "$@" ;;
  *) echo "usage: autopilot-config.sh {path|exists|dump|get <jqfilter> [def]|detect|backlog|validate [file]|ensure [--reconfigure]|load [--reconfigure]}" >&2; exit 2 ;;
esac
