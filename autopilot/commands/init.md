---
description: One-time repo initialization for all autopilot commands — verifies/installs gstack, ensures .claude/autopilot.config.json, makes the backlog tracker the repo's tracker (binds its projects — several per repo — and switches off Jira/GitHub), bootstraps the design system (gstack /design-consultation → DESIGN.md) and baseline documentation (gstack /document-generate), then writes the .claude/autopilot.init.json marker that /autodev, /autoship and /autopilot require.
argument-hint: "[--force] [--skip-backlog] [--skip-design] [--skip-docs]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, AskUserQuestion, mcp__backlog__list_projects, mcp__backlog__create_project, mcp__backlog__update_project
---

# /autopilot:init — make this repo autopilot-ready

Run once per repository, **before** the first `/autodev`, `/autoship` or
`/autopilot` run. Those commands check for the marker this
command writes (`.claude/autopilot.init.json`) and stop if it is missing.
Idempotent: re-running verifies each item and only fixes what is missing;
`--force` redoes everything.

## Step 1 — gstack present?

The autopilot QA steps (and review/canary, when configured) and this
command's bootstraps delegate to gstack skills (/qa, /qa-only, /browse, /review,
/canary, /design-consultation, /document-generate), so gstack is a hard
dependency:

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

## Step 3 — backlog tracker (skip with `--skip-backlog`)

The **backlog** tracker (ai-backlog — hosted, or local on the operator's machine) is the tracker: its
issues open new Constructor workspaces that start with `/autopilot:autopilot` (size XS–S) or
`/autopilot:autodev` (M and up) — which only work in a repo this command has initialized — and
`/autodev` / `/autoship` key their commits on its issues, move them, and file follow-ups
(`lib/follow-ups.md`) into it. One repo can hold several
projects (a monorepo's sales / marketing / admin areas); each says which part of the repo it covers.

**Repo root** — the main checkout, which Constructor workspaces are worktrees of (not this worktree):
`git worktree list --porcelain | sed -n '1s/^worktree //p'`.

1. **Reachable?** The `mcp__backlog__*` tools must resolve (the server name the operator registered;
   `backlog` by convention). If they don't, ask the tracker itself:
   `"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" backlog` — it goes to `AUTOPILOT_BACKLOG_URL` when
   set, else where the `backlog` MCP server in Claude Code's config points, with its headers
   (`AUTOPILOT_BACKLOG_TOKEN` replaces its token), else to a local tracker at `http://127.0.0.1:4400`,
   and prints `up <keys>`, `refused <url> <code>` (401: no token for it, or a wrong one; 403: no
   access, or a host it doesn't answer on), `down <url> <code>` (configured; `000` = no answer, else
   not as the tracker) or `unusable` (a `backlog` server with no http URL — stdio, a proxy command);
   nothing means no tracker is configured and none runs here. Either way **don't block init** — report it as pending with the operator follow-up: register the tracker's MCP once — a
   hosted one with its token
   (`claude mcp add --transport http --scope user backlog https://<tracker>/mcp --header "Authorization: Bearer <token>"`;
   Codex: `codex mcp add backlog --url https://<tracker>/mcp --bearer-token-env-var BACKLOG_TOKEN`),
   a local one after starting it (`corepack pnpm start` in the ai-backlog repo)
   (`claude mcp add --transport http --scope user backlog http://127.0.0.1:4400/mcp`) — then re-run
   `/autopilot:init` in a new session.
2. **What's there** — `mcp__backlog__list_projects` with `repoPath` = repo root (already bound, with
   their scopes) and without a filter (every project, to offer and to know the taken keys).
3. **Ask** which projects cover this repo — one `AskUserQuestion`, `multiSelect: true`:
   - the bound projects stay bound unless the operator unticks them ("keep `<KEY>` — `<name>`");
   - unbound projects whose name fits the repo or one of its areas;
   - **New project(s)** — one per distinct area when the repo is a monorepo (`apps/*`, `packages/*`,
     top-level product modules), else one for the whole repo: name, key (2–4 letters, not taken),
     scope. A follow-up question confirms or edits them.
   More than 4 options → the strongest 4 in the question, the rest listed in text.
4. **Bind** — `create_project` for new ones; `update_project` with `repoPath` = repo root for picked
   existing ones (a project lives in one repo — say so when it moves from another) and with `repoPath:
   ""` for unticked ones. **Every bound project needs a scope** — directories, apps or the product
   area it covers; propose one from the repo layout when it's empty and set it with `update_project`:
   it's how work is routed when the repo has several projects.
5. **Make it the repo's tracker** — set the config's tracker block, replacing whatever was there
   (`none`, or `jira` / `github` the operator is moving off — the config is committed, so
   say that everyone's autopilot runs in this repo move with it, and name the old tracker in the
   report: its open issues stay where they were). `keyPrefix` = the default project for new issues
   (asked when several are bound); keys of every bound project are valid. Keep `keyRequired` /
   `autoCreateIssue` / `git.commitStyle` as they were:
   ```json
   "tracker": { "type": "backlog", "mcp": "mcp__backlog", "keyPrefix": "<default KEY>",
                "keyRequired": false, "autoCreateIssue": false,
                "shipStatus": "done", "shipStatusVia": [], "followUps": "ask" }
   ```
   Then `"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" validate`; it rides along in the init commit
   (Step 6). The operator can decline the switch — then the projects stay bound, and follow-ups still
   go to them.

A `tracker.type` the schema no longer lists (a retired tracker) can't stay in the config — `validate`
fails on it. Step 5 replaces it like any other; when the operator declines, or this step is skipped
or pending, set it to `none` (without `mcp` and `shipStatus`) and say so in the report.

## Step 4 — design system bootstrap (skip with `--skip-design`)

gstack's design skills (`/design-review`, `/plan-design-review`) and agents
that find it follow `DESIGN.md`; without it every autonomous run reinvents the
product's aesthetics.

- Repo has a UI? Heuristic: framework deps (react/vue/svelte/next/vite) in
  `package.json`, or `*.html` entry points, or an existing frontend dir. No UI
  (pure API/CLI/library) → record `"design": "not-applicable"` and move on.
- UI and no `DESIGN.md` → invoke gstack's `/design-consultation` (Skill tool;
  it researches the product, proposes a design system, and writes `DESIGN.md`).
  It is interactive — it needs the operator's taste answers. In a headless or
  non-interactive session, record `"design": "pending"` and tell the operator
  to run `/design-consultation` themselves; do not fake a design system.

## Step 5 — documentation bootstrap (skip with `--skip-docs`)

A baseline gives autonomous runs and reviewers something to read and keep up
to date; they do not create a doc culture from zero.

- Assess: README with real sections? `docs/` (or equivalent) present? If the
  Diataxis quadrants are essentially empty for the product's main flows →
  invoke gstack's `/document-generate` scoped to a **baseline**: reference +
  how-to for the main user flows. Do not boil the ocean here — grow coverage
  feature by feature later (e.g. gstack `/document-release`).
- Record `"docs": "generated" | "already-present" | "pending"`.

## Step 6 — write the marker + commit

```bash
cd "$(git rev-parse --show-toplevel)"
cat > .claude/autopilot.init.json <<EOF
{
  "version": 1,
  "initializedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "gstack": "<global|vendored> <version>",
  "design": "<done|pending|not-applicable|skipped>",
  "docs": "<generated|already-present|pending|skipped>"
}
EOF
git add .claude/autopilot.init.json
```

Commit together with anything the steps produced (`DESIGN.md`, generated docs,
config): `chore: autopilot init (gstack, design, docs)`.
Any `"pending"` value is allowed in the marker — it unblocks the other
commands but MUST be listed in the final report as operator follow-up.

## Step 7 — report

One compact block: gstack (path + version, installed or found), config
(created or existing), backlog (projects bound to this repo with their scopes, the default one, the
tracker it replaced / declined / pending + why), design (DESIGN.md written / pending / n-a), docs
(what was generated), marker path, and the exact follow-ups if anything is pending.
