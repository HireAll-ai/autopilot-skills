---
description: Scaffold the software factory into the current repo — copy the fabro lanes (express/iterate/feature/bugfix-express/bugfix-deep), hooks, and e2e machinery from the plugin snapshot, personalize factory/config.env for this project, validate the graphs, and commit. After this, /factory can dispatch runs here.
argument-hint: "[--from <path-to-live-factory-repo>] [--force]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill
---

# /factory-init — make this repo factory-enabled

Copies the factory scaffold into the current repository and personalizes it.
Source of truth: the plugin's bundled snapshot at
`${CLAUDE_PLUGIN_ROOT}/lib/factory-scaffold/` — or a live factory repo when
`--from <path>` is given (its `factory/` and `.fabro/workflows/` are used
instead; useful when the canonical factory has evolved past the snapshot).

## Step 1 — Preflight

1. Must be a git repo; refuse to scaffold a dirty working tree unless `--force`.
2. If `factory/` or `.fabro/workflows/` already exist: show what differs
   (file-level) and ask — update (overwrite factory machinery, PRESERVE
   `factory/config.env`) or abort. Never silently overwrite `config.env`.
3. fabro CLI present? If not, note it and continue (scaffold still lands;
   validation is skipped): `brew install fabro-sh/tap/fabro-nightly`.

## Step 2 — Copy

From the scaffold source:
- `factory/` → repo `factory/` (workflows *.dot, hooks/, e2e/, deploy/, README.md)
- `fabro-workflows/<lane>/` → repo `.fabro/workflows/<lane>/` (all five lanes)
- `factory/config.env.template` → repo `factory/config.env` (only if absent)
- `chmod +x factory/hooks/*.sh`

## Step 3 — Personalize `factory/config.env`

Detect and write (confirm with the user in one compact message, not one
question per line):
- `FACTORY_TEST_CMD`: from package.json scripts.test / Cargo.toml / pyproject.
- `FACTORY_DEV_CMD` + `FACTORY_PREVIEW_PORT`: from scripts.dev/start; default port 3100.
- `FACTORY_BASE_BRANCH`: `git remote show origin` HEAD branch.
- `FACTORY_PREVIEW_PLATFORM`: `local` unless the user names Coolify/DO infra —
  then collect `COOLIFY_URL`/`COOLIFY_TOKEN`/`COOLIFY_APP_UUID`/`PREVIEW_DOMAIN`.
- `FACTORY_PROD_URL`: ask if the product has a live URL; else leave commented.

## Step 4 — Validate & commit

1. If fabro is installed: `fabro validate factory/workflows/<lane>.dot` for all
   five lanes and `fabro preflight <lane>` for one of them; report failures
   instead of committing broken graphs.
2. Commit: `factory: scaffold software factory (lanes, hooks, e2e) via /factory-init`.
3. Print next steps:
   - server: local `fabro server start` / remote `export FABRO_SERVER=...`
   - credentials: `fabro install --non-interactive --llm-provider anthropic ...`
     (or an Anthropic-compatible proxy via `ANTHROPIC_BASE_URL`), GitHub token
   - first run: `/factory <task>` or `fabro run express-lane --goal "..."`

## Cautions

- The snapshot is a copy, not a subscription: rerun `/factory-init` (update
  path) after upgrading the plugin to pull newer machinery. `config.env` is
  always preserved.
- Do not scaffold repos that already run a different orchestration for the
  same lifecycle without pointing out the overlap to the user.
