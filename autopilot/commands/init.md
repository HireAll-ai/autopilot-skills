---
description: One-time repo initialization for all autopilot commands — verifies/installs gstack, ensures .claude/autopilot.config.json, offers to bind the repo to its projects in the local backlog tracker (several per repo), scaffolds the software factory when fabro is available, bootstraps the design system (gstack /design-consultation → DESIGN.md) and baseline documentation (gstack /document-generate), then writes the .claude/autopilot.init.json marker that /autodev, /autoship, /autopilot and /factory require.
argument-hint: "[--force] [--skip-backlog] [--skip-design] [--skip-docs] [--skip-factory]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, AskUserQuestion, mcp__backlog__list_projects, mcp__backlog__create_project, mcp__backlog__update_project
---

# /autopilot:init — make this repo autopilot-ready

Run once per repository, **before** the first `/autodev`, `/autoship`,
`/autopilot` or `/factory` run. Those commands check for the marker this
command writes (`.claude/autopilot.init.json`) and stop if it is missing.
Idempotent: re-running verifies each item and only fixes what is missing;
`--force` redoes everything.

## Step 1 — gstack present?

The factory lanes and the autopilot QA/review/canary steps delegate to gstack
skills (/qa, /cso, /design-consultation, /document-generate, /document-release,
/canary), so gstack is a hard dependency:

```bash
GSTACK=""
[ -f "$HOME/.claude/skills/gstack/SKILL.md" ] && GSTACK="$HOME/.claude/skills/gstack"
[ -z "$GSTACK" ] && [ -f ".claude/skills/gstack/SKILL.md" ] && GSTACK=".claude/skills/gstack (vendored)"
echo "GSTACK: ${GSTACK:-MISSING}"
[ -n "$GSTACK" ] && cat "${GSTACK%% *}/VERSION" 2>/dev/null
```

- **MISSING** → install it (this is the documented gstack install, safe to run):

```bash
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack \
  && (cd ~/.claude/skills/gstack && ./setup)
```

  If the clone or setup fails (offline, git missing), **STOP** and report — do
  not write the init marker without gstack.

## Step 2 — project config

Same loader as the other commands, minus the init-marker check (this command writes the marker):

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" ensure; echo "rc=$?"     # add --reconfigure with --force
```

- **rc=0** → config present (stdout). Keep it in context for the steps below.
- **rc=3** → stdout is an autodetected draft: Read `${CLAUDE_PLUGIN_ROOT}/lib/config-interview.md`
  and run that interview.
- **rc=2 / other** → loader hard error on stderr (commonly: `jq` missing) → surface it, **STOP**.

## Step 3 — backlog projects (skip with `--skip-backlog`)

The local **backlog** tracker (ai-backlog) is personal: it knows which of its projects live in which
repo, and one repo can hold several (a monorepo's sales / marketing / admin areas). Binding is data
in the tracker — each project's `repoPath` and `scope` — **never** the committed config, so teammates
without the tracker are unaffected and a repo on Jira / Linear / GitHub keeps its tracker; the backlog
then runs alongside it. `/autodev` and `/autoship` find the repo's projects at run time and route
follow-up tasks (`lib/follow-ups.md`) to them by scope.

**Repo root** — the main checkout, which Conductor workspaces are worktrees of (not this worktree):
`git worktree list --porcelain | sed -n '1s/^worktree //p'`.

1. **Reachable?** The `mcp__backlog__*` tools must resolve (the server name the operator registered;
   `backlog` by convention). If they don't, see whether the tracker runs at all:
   `curl -fsS --max-time 2 http://127.0.0.1:4400/api/projects`. Either way **don't block init** —
   report it as pending with the operator follow-up: start the tracker (`corepack pnpm start` in the
   ai-backlog repo), register its MCP once
   (`claude mcp add --transport http --scope user backlog http://127.0.0.1:4400/mcp`; Codex:
   `codex mcp add backlog --url http://127.0.0.1:4400/mcp`), then re-run `/autopilot:init` in a new
   session.
2. **What's there** — `mcp__backlog__list_projects` with `repoPath` = repo root (already bound, with
   their scopes) and without a filter (every project, to offer and to know the taken keys).
3. **Ask** which projects cover this repo — one `AskUserQuestion`, `multiSelect: true`:
   - the bound projects stay bound unless the operator unticks them (list them, ticked by default in
     the wording: "keep `<KEY>` — `<name>`");
   - unbound projects whose name fits the repo or one of its areas;
   - **New project(s)** — propose one per distinct area when the repo is a monorepo (`apps/*`,
     `packages/*`, top-level product modules) or one for the whole repo otherwise: name, key (2–4
     letters, not taken), scope. A follow-up question confirms or edits them.
   More than 4 options → the strongest 4 in the question, the rest listed in text.
4. **Bind** — `create_project` for new ones; `update_project` with `repoPath` = repo root for picked
   existing ones (a project lives in one repo — say so when it moves from another) and with `repoPath:
   ""` for unticked ones. **Every bound project needs a scope** — directories, apps or the product
   area it covers; propose one from the repo layout when it's empty and set it with `update_project`:
   it's how work gets routed when the repo has several projects.
5. **Primary tracker** — only when `.tracker.type` is `none`: offer to make the backlog this repo's
   tracker, then set and validate the tracker block (`keyPrefix` = the default project for new issues,
   asked when there are several; keys of every bound project stay valid):
   ```json
   "tracker": { "type": "backlog", "mcp": "mcp__backlog", "keyPrefix": "<default KEY>",
                "keyRequired": false, "autoCreateIssue": false,
                "shipStatus": "done", "shipStatusVia": [], "followUps": "ask" }
   ```
   `"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" validate`; it rides along in the init commit
   (Step 7). Never replace `jira` / `linear` / `github` — that config is the team's.

The binding lives in the tracker, so nothing of it goes into the committed marker — report it in Step 8.

## Step 4 — factory scaffold (skip with `--skip-factory`)

If the fabro CLI is installed (`command -v fabro`) and `factory/` or
`.fabro/workflows/` is absent → run `/factory-init` now (it scaffolds the five
lanes, hooks incl. canary, e2e machinery, and personalizes `factory/config.env`).
If fabro is missing: note it in the report (`brew install fabro-sh/tap/fabro-nightly`)
and record `"factory": "skipped-no-fabro"` — `/autodev` and `/autoship` work
without the factory; `/factory` does not.

## Step 5 — design system bootstrap (skip with `--skip-design`)

The factory's spec/implement/iterate prompts follow `DESIGN.md` when it
exists; without it every autonomous run reinvents the product's aesthetics.

- Repo has a UI? Heuristic: framework deps (react/vue/svelte/next/vite) in
  `package.json`, or `*.html` entry points, or an existing frontend dir. No UI
  (pure API/CLI/library) → record `"design": "not-applicable"` and move on.
- UI and no `DESIGN.md` → invoke gstack's `/design-consultation` (Skill tool;
  it researches the product, proposes a design system, and writes `DESIGN.md`).
  It is interactive — it needs the operator's taste answers. In a headless or
  non-interactive session, record `"design": "pending"` and tell the operator
  to run `/design-consultation` themselves; do not fake a design system.

## Step 6 — documentation bootstrap (skip with `--skip-docs`)

Autonomous runs keep docs current only if a baseline exists (the lanes'
docs-update stage edits docs, it does not create a doc culture from zero).

- Assess: README with real sections? `docs/` (or equivalent) present? If the
  Diataxis quadrants are essentially empty for the product's main flows →
  invoke gstack's `/document-generate` scoped to a **baseline**: reference +
  how-to for the main user flows. Do not boil the ocean here — the per-run
  docs stage grows coverage feature by feature.
- Record `"docs": "generated" | "already-present" | "pending"`.

## Step 7 — write the marker + commit

```bash
cd "$(git rev-parse --show-toplevel)"
cat > .claude/autopilot.init.json <<EOF
{
  "version": 1,
  "initializedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "gstack": "<global|vendored> <version>",
  "factory": <true|false or "skipped-*">,
  "design": "<done|pending|not-applicable|skipped>",
  "docs": "<generated|already-present|pending|skipped>"
}
EOF
git add .claude/autopilot.init.json
```

Commit together with anything the steps produced (`DESIGN.md`, generated docs,
factory scaffold, config): `chore: autopilot init (gstack, factory, design, docs)`.
Any `"pending"` value is allowed in the marker — it unblocks the other
commands but MUST be listed in the final report as operator follow-up.

## Step 8 — report

One compact block: gstack (path + version, installed or found), config
(created or existing), backlog (projects bound to this repo with their scopes / declined / pending +
why; primary tracker or alongside `<type>`), factory (scaffolded / present / skipped + why), design
(DESIGN.md written / pending / n-a), docs (what was generated), marker path,
and the exact follow-ups if anything is pending.
