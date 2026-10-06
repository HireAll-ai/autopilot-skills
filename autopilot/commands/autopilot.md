---
description: Full autonomous cycle, no verification stop — /autodev (plan → build → test → local QA (+ opt-in --e2e, video) → draft PR) flows straight into /autoship (auto-reviewer pass bar → required checks green → merge → deploy → canary), finishing with an automated QA pass (ON by default). Takes any task — no scope or risk filter; the merge gates still apply. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[spec/plan file | feature description] [--no-qa] [--e2e] [deploy-url] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent, AskUserQuestion, WebFetch, mcp__jira-server__get_issue, mcp__jira-server__get_transitions, mcp__jira-server__transition_issue
---

# /autopilot — feature → merged → deployed, in one run

> **Invoking `/autopilot` IS your authorization — start immediately.** Do not ask "are you sure",
> do not re-warn that merging / deploying is destructive, do not pause before Step 1. Typing this
> command is the explicit, durable go-ahead for the whole cycle — it satisfies the "confirm
> hard-to-reverse / outward-facing actions" reflex up front. Only the one-time config interview
> (Step 0.0) can precede Step 1.

`/autodev` + `/autoship` back-to-back. The human verification gate that normally sits between them is
**replaced by an automated QA pass** (the `--qa` mode of `/autoship`, ON by default here — the only
check left that exercises the deployed build; the CI / auto-reviewer / canary hard gates still apply).

**Project-independent.** All facts from `.claude/autopilot.config.json`.

Pipeline: brainstorm/spec → **`/autopilot`** = autodev Steps 0–5 (draft PR, **no stop**) → autoship
Steps 0–6 (ready → review loop → checks → merge → canary → QA → ticket ship-status) → one combined report.

## Step 0.0 — Init check + load project config (once for the whole run)

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" load; echo "rc=$?"     # add --reconfigure if passed
```
- **rc=0** → stdout **is** the config — keep it in context. This is the **only** load in the run:
  both phases below get `--preloaded` and skip their own Step 0.0.
- **rc=4** → `NOT_INITIALIZED` → **STOP.** Tell the user to run **`/autopilot:init`** first (gstack,
  config, factory scaffold, DESIGN.md + docs bootstrap), then re-run this command.
- **rc=3** → no config (or `--reconfigure`): Read `${CLAUDE_PLUGIN_ROOT}/lib/config-interview.md`,
  run it, then continue.
- **rc=2 / other** → hard loader error on stderr (commonly: `jq` missing) → surface it, **STOP**.

## Scope — any task

`/autopilot` does **not** filter tasks by type or risk. Migrations, auth/permissions, payments,
refactors, deletions, infra/config — whatever was asked, build and ship it. Don't route it to the
two-step flow, don't ask "are you sure", and don't stop mid-run because the work turns out to be
sensitive. The repo's own docs (`.rules.docs`) still decide **how** to do it (migration conventions,
API policy, …), not **whether**.

What still stops a run is unrelated to task type — it's the cases where continuing would mean
**guessing** or **shipping something broken**:
- an architecture fork with no clear winner, or a 3rd-party API shape you can't confirm from docs;
- any `/autoship` hard gate (review pass bar, CI, canary, blocking QA regression).

When the run touches a sensitive area (data migration, auth, payments, destructive/irreversible
change), say so in the final report — what changed there and how to roll it back — so it gets a human
look after the fact.

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

1. **Invoke the `autopilot:autodev` skill** (Skill tool — the plugin-namespaced name) with the
   spec/description argument **plus `--preloaded`** (config already loaded above).
   **One override — its Step 5 does not stop:** do everything Step 5 says (commit, push, draft PR
   with the populated template, print the handoff block for the record), then **continue straight to
   step 2 below** instead of waiting for the user. Everything else in `/autodev` applies — the autonomy contract
   **minus its destructive/irreversible-scope STOP** (see Scope: `/autopilot` takes any task; STOP only
   on high-stakes architecture forks and unconfirmable 3rd-party API shapes), repo rules
   (`.rules.docs`), testing strategy, mandatory local browser QA for UI features.
   **Pass `--e2e` through** if the user did — autodev's Step 4.5 then runs the local fix-loop e2e
   (recorded when video is enabled).
2. **Invoke the `autopilot:autoship` skill** with **`--preloaded`**, the deploy URL and **`--qa`**
   (omit `--qa` only if the user passed `--no-qa`), plus **`--e2e`** if the user passed it.
   **No overrides** — every hard gate applies: auto-reviewer at `.review.passBar` + zero unresolved threads, full CI green,
   template-complete PR body, clean canary, QA without blocking regressions, and only then the ticket
   → `.tracker.shipStatus`.
3. **Combined final report** — one message: a one-line top summary (what shipped, where to click on
   the deployed env), then autodev's handoff block, autoship's report block, the QA verdict, and —
   if any — **Sensitive areas touched** (what changed, how to roll it back).

## Safety
- This removes the *verification* gate, the launch-confirmation prompt **and any task-type/risk
  filter** — not the *quality* gates: every hard gate in `/autoship` and the "don't guess" STOPs in
  `/autodev` still stop the run.
- Nothing merges that isn't at `.review.passBar` + fully green CI.
- A canary problem, a blocking QA regression, or (with `--e2e`) a failing deployed e2e scenario leaves
  the ticket untouched and surfaces a revert / fix-forward choice — never auto-revert silently.
- Project-independent: all facts from `.claude/autopilot.config.json`. Ships as the `autopilot` Claude Code plugin
  (`claude plugin marketplace add HireAll-ai/autopilot-skills`).
