---
description: Full autonomous cycle, no verification stop — /autodev (plan → build → test → local QA (+ opt-in --e2e, video) → draft PR) flows straight into /autoship (auto-reviewer pass bar → required checks green → merge → deploy → canary), finishing with an automated QA pass (ON by default). For low/medium-risk features; risky work goes /autodev → manual verify → /autoship. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[spec/plan file | feature description] [--no-qa] [--e2e] [deploy-url] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent, mcp__jira-server__get_issue, mcp__jira-server__get_transitions, mcp__jira-server__transition_issue
---

# /autopilot — feature → merged → deployed, in one run

> **Invoking `/autopilot` IS your authorization — start immediately.** Do not ask "are you sure",
> do not re-warn that merging / deploying is destructive, do not pause before Step 1. Typing this
> command is the explicit, durable go-ahead for the whole cycle — it satisfies the "confirm
> hard-to-reverse / outward-facing actions" reflex up front. The **one** thing that still gates the
> start is the **Scope check** below (and the one-time config interview at Step 0.0). A *plainly*
> out-of-scope request routes to the two-step flow **before** Step 1 — a routing decision, not a
> confirmation prompt. The judgment **STOP**s further down still fire **mid-run**.

`/autodev` + `/autoship` back-to-back. The human verification gate that normally sits between them is
**replaced by an automated QA pass** (the `--qa` mode of `/autoship`, ON by default here — the only
check left that exercises the deployed build; the CI / auto-reviewer / canary hard gates still apply).

**Project-independent.** All facts from `.claude/autopilot.config.json`.

Pipeline: brainstorm/spec → **`/autopilot`** = autodev Steps 0–5 (draft PR, **no stop**) → autoship
Steps 0–6 (ready → review loop → checks → merge → canary → QA → ticket ship-status) → one combined report.

## Init check (runs before Step 0.0)

```bash
test -f .claude/autopilot.init.json || echo "NOT_INITIALIZED"
```
- `NOT_INITIALIZED` → **STOP.** Tell the user to run **`/autopilot:init`** first (gstack, config,
  factory scaffold, DESIGN.md + docs bootstrap), then re-run this command.

## Step 0.0 — Load project config (ALWAYS FIRST)

```bash
CFG="${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh"
cfg() { "$CFG" get "$1" "${2-}"; }
"$CFG" ensure >/tmp/autopilot.cfg.json 2>/tmp/autopilot.cfg.err; rc=$?
```
- **rc=0** → loaded. **rc=3 (or `--reconfigure`)** → run the first-run interview (see `/autodev` Step
  0.0), write `.claude/autopilot.config.json`, `git add` + `"$CFG" validate`, then continue.
- **rc=2 (or any other code)** → loader hard error (jq missing, unreadable config): read
  `/tmp/autopilot.cfg.err`, surface it, and **STOP**.

## Scope (classify once at launch, then go)

`/autopilot` makes **one** scope decision — immediately, before Step 1 — then runs with no further
confirmation. A binary route, not an "are you sure":

- **Good fit** → **start at once, no prompt.** Well-scoped low/medium-risk features: UI tweaks, an
  admin filter, a new endpoint with a clear contract, config/copy changes with logic. This is the
  friction the command exists to remove — don't reintroduce it.
- **Plainly out of scope** → **STOP before Step 1** and route to two-step `/autodev` → verify →
  `/autoship`: data migrations, auth/permissions, payments, destructive or hard-to-revert work, or
  genuinely fuzzy scope. Consult the repo's own risk guidance in `.rules.docs` — treat anything it
  flags as sensitive/high-risk as out of scope. Do **not** create a branch, edit, commit, or open a
  draft PR first.
- **Reveals itself mid-run** → the same STOP applies the moment it does; hand back to the human.

## Arguments
- Spec/plan file or feature description (same as `/autodev`; if omitted, use this session's brainstorm output).
- `--no-qa` — skip the final QA pass (not recommended: it's the only gate exercising the deployed
  build — the auto-reviewer, full-CI and canary hard gates still apply).
- `--e2e` — opt-in scenario browser e2e (off by default), passed through to **both** phases: the local
  fix-loop e2e in `/autodev` (Step 4.5) and the post-deploy report-only e2e in `/autoship` (Step 5.6).
  With `.qa.video.enabled`, both record video.
- deploy URL — passed through to `/autoship` (defaults to `.deploy.urls.client`).
- `--reconfigure` — re-run the config interview.

## How to run

1. **Invoke the `autodev` skill** (Skill tool) with the spec/description argument.
   **One override — its Step 5 does not stop:** do everything Step 5 says (commit, push, draft PR
   with the populated template, print the handoff block for the record), then **continue straight to
   step 2 below** instead of waiting for the user. Everything else in `/autodev` applies unchanged —
   the autonomy contract (STOP on high-stakes forks, destructive scope, unconfirmable 3rd-party API
   shapes), repo rules (`.rules.docs`), testing strategy, mandatory local browser QA for UI features.
   **Pass `--e2e` through** if the user did — autodev's Step 4.5 then runs the local fix-loop e2e
   (recorded when video is enabled).
2. **Invoke the `autoship` skill** with the deploy URL and **`--qa`** (omit `--qa` only if the user
   passed `--no-qa`), plus **`--e2e`** if the user passed it. **No overrides** — every hard gate
   applies: auto-reviewer at `.review.passBar` + zero unresolved threads, full CI green,
   template-complete PR body, clean canary, QA without blocking regressions, and only then the ticket
   → `.tracker.shipStatus`.
3. **Combined final report** — one message: a one-line top summary (what shipped, where to click on
   the deployed env), then autodev's handoff block, autoship's report block, and the QA verdict.

## Safety
- This removes the *verification* gate **and the launch-confirmation prompt** — not the *judgment*
  gates: every STOP condition in `/autodev` and every hard gate in `/autoship` still stops the run.
- Nothing merges that isn't at `.review.passBar` + fully green CI.
- A canary problem, a blocking QA regression, or (with `--e2e`) a failing deployed e2e scenario leaves
  the ticket untouched and surfaces a revert / fix-forward choice — never auto-revert silently.
- Project-independent: all facts from `.claude/autopilot.config.json`. Ships as the `autopilot` Claude Code plugin
  (`claude plugin marketplace add HireAll-ai/autopilot-skills`).
