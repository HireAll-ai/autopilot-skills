---
description: Autonomous feature build — plan → implement → test → quality-review (+ opt-in --e2e browser e2e, optionally recorded to video), ending in a fully implemented & tested feature on the branch plus a DRAFT PR (CI pre-warmed; the configured auto-reviewer runs once /autoship flips it to ready), then STOPS for your verification. Does not ship — a draft PR is not mergeable. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[spec/plan file | feature description] [--e2e] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent
---

# /autodev — plan → build → test, then wait for verification

Run this **after** brainstorming / `/office-hours`, when intent and scope are clear. It plans
the work, implements it autonomously, tests it, runs a local quality pass, then **STOPS and
hands the feature to you to verify**. It does **not** ship.

Pipeline position: brainstorming / `/office-hours` → **`/autodev`** → *(you verify)* → `/autoship`.

**Project-independent.** Everything project-specific (ticket prefix, package-manager commands, base
branch + protection, review gate, deploy targets, QA/video) is read from `.claude/autopilot.config.json`
at Step 0.0 — the command body has **no hardcoded project facts**. First run in a repo without that
file → a short detect-and-confirm interview writes it (Step 0.0).

Input (`$ARGUMENTS`, optional):
- A spec/plan file path (e.g. `<planDir>/...md`), or a short feature description.
- If omitted, use the **brainstorm/office-hours output from this conversation** as the source of truth.
- `--e2e` — opt-in scenario-based browser e2e (Step 4.5). When passed, it **replaces** the heuristic
  browser-QA pass for UI features (one browser pass, not two). When `qa.video.enabled` is true in
  config, the scenario walk is **recorded to video** (Step 4.5). Off by default.
- `--reconfigure` — re-run the config interview (Step 0.0) even if a config already exists.

## Init check (runs before Step 0.0)

```bash
test -f .claude/autopilot.init.json || echo "NOT_INITIALIZED"
```
- `NOT_INITIALIZED` → **STOP.** This repo has not been initialized for autopilot. Tell the user to
  run **`/autopilot:init`** first (verifies/installs gstack, ensures the project config, scaffolds
  the factory when fabro is available, bootstraps `DESIGN.md` and baseline docs), then re-run this
  command. Do not improvise a partial init here.

## Step 0.0 — Load project config (ALWAYS FIRST)

```bash
CFG="${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh"
cfg() { "$CFG" get "$1" "${2-}"; }                 # cfg '.commands.typecheck'  → value
"$CFG" ensure >/tmp/autopilot.cfg.json 2>/tmp/autopilot.cfg.err; rc=$?
```
- **rc=0** → config loaded. Read any value with `cfg '.<jq.path>'` (e.g. `cfg '.git.baseBranch'`).
- **rc=3 (or `--reconfigure`)** → **no config yet.** `/tmp/autopilot.cfg.json` holds an **autodetected
  draft** (package manager, base branch + protection, ticket prefix, health URL). Run the
  **first-run interview**: show the developer the detected values and confirm/fill the gaps the
  detector can't know — `tracker.type`/`tracker.mcp`/`tracker.shipStatus`, `review.gate`+`skill`,
  `deploy.urls`, and whether to enable `qa.video`. Prefer `AskUserQuestion` (Conductor) for the
  choices. Then **write** the completed JSON to `.claude/autopilot.config.json`, `git add` it, and
  validate: `"$CFG" validate`. This is a one-time cost per repo; it's committed and reused by the
  whole team and by `/autoship`.
- **rc=2 (or any other code)** → the loader hit a hard error (jq not installed, unreadable config,
  or a bad subcommand). Read `/tmp/autopilot.cfg.err`, surface the exact message (commonly: install
  `jq`), and **STOP** — do not proceed to `cfg`/build steps.

Throughout this document, `<name>` placeholders resolve from config: `<KEY>` = a `<keyPrefix>-NNN`
ticket key, `<base>` = `.git.baseBranch`, `<typecheck>` = `.commands.typecheck`, `<planDir>` =
`.rules.planDir`, etc. If a command value is empty (`""`), that step is **not applicable to this
project — skip it and say so** (don't invent one).

## Required skills (verify installed before running)
If any referenced skill doesn't resolve, install it — don't skip the step silently:
- **superpowers:** `writing-plans`, `test-driven-development`, `executing-plans`,
  `subagent-driven-development`.
- **The QA/review skills named in config** — `.review.localReviewers` (Step 4), `.qa.qaSkill`
  (Step 4, required for UI features), `.qa.browseSkill` (Step 4.5, only with `--e2e`). `/run` optional.

## What it does NOT do
- No **mergeable** PR — Step 5 opens a **draft** PR (pre-warms CI while you verify),
  but never marks it ready, never merges, never deploys, never touches the tracker. That's
  `/autoship` + your explicit go.
- It does not push past a genuine high-stakes fork silently (see Autonomy contract).

## Autonomy contract
- Run **autonomously to completion** — do not stop for approval between tasks. The single human
  gate is the **final verification** (Step 5). *(Exception: the one-time config interview at Step 0.0.)*
- **Exception (STOP and ask):** high-stakes ambiguity — an architecture fork with no clear winner,
  destructive/irreversible scope, or a **3rd-party API contract you cannot confirm from docs** (the
  repo rules forbid guessing external API shapes — use WebFetch/context7 first; if still unknown,
  stop and say so). Routine decisions: make the sensible call and **record it** for verification.

## Repo rules to follow (do not re-derive — obey the repo's own docs)
Read and obey the rule docs named in **`.rules.docs`** (typically `CLAUDE.md` / `AGENTS.md` and
linked dev docs). Those are the source of truth for this project's architecture, coding standards,
testing strategy, UI-change constraints, and 3rd-party-API policy. Do **not** paste another
project's rules here — follow the ones this repo ships.

---

## Step 0 — Preflight

```bash
git rev-parse --abbrev-ref HEAD
git status --porcelain
KEYPREFIX=$(cfg '.tracker.keyPrefix'); BASE=$(cfg '.git.baseBranch')
```

- If `.tracker.keyRequired` is true, the change needs a `<KEY>` (`<keyPrefix>-NNN`) ticket. If the
  branch has no key and the work clearly has none, create the issue via the configured tracker
  (`.tracker.type`/`.tracker.mcp`, e.g. `<mcp>__create_issue`); otherwise ask for the key — **don't
  invent one**. (`.tracker.type == none` → skip all ticket handling.)
- Branch should follow `.git.branchPattern` off `<base>`; if you're **on `<base>`**, **STOP** and ask
  to branch first (in Conductor: a fresh workspace from `<base>`). If you're on a validly-scoped
  feature branch whose name can't be changed, keep it and carry `<KEY>` in commits/PR instead.
- Gather the source of truth: `$ARGUMENTS` file/description, or this session's brainstorm output.

## Step 1 — Plan

1. **Size the task first (tiered planning).** Small change — ≈≤3 files, no architecture fork,
   one obvious approach — plan **inline in TodoWrite only**, no plan file. Anything bigger: invoke
   **`writing-plans`** → a task-by-task plan at `<planDir>/<date>-<KEY>-<slug>.md` (a spec in
   `.rules.specDir` first if the feature is large).
2. Mirror the plan tasks into **TodoWrite** and work them one at a time, marking each complete as
   you go (don't batch-complete).
3. For non-trivial features, self-review the plan against eng dimensions (architecture fit, data
   flow, edge cases, test coverage) and tighten it. *(Optional: run `/autoplan` on the plan file
   first for the full review gauntlet.)*

For broad codebase understanding before designing, dispatch parallel explorer agents (Agent tool)
and read the files they surface — then implement.

## Step 2 — Implement (autonomous)

Work the plan task-by-task:
- Follow the chosen architecture and **all repo rules** (`.rules.docs`).
- Match surrounding code (naming, patterns, comment density).
- Commit incrementally with `<KEY>:` prefixed messages (what + why). Keep commits coherent per
  logical unit; never `git add -A` blindly — stage intentional files.
- `<typecheck>` must pass before each commit (skip only if `.commands.typecheck` is empty).

## Step 3 — Test

> **Test-gate behavior.** If the repo's testing docs (`.rules.docs`) prescribe an "ask before
> writing tests" checkpoint, invoking `/autodev` **is** the opt-in to skip that mid-run prompt: it
> writes tests autonomously and moves the checkpoint to the Step 5 verification gate (code + tests
> reviewed together). Want the interactive test-gate instead? Use the manual flow.

Test **only what the repo's Testing Strategy (`.rules.docs`) says to test** — don't generate slop.
Typically: **unit** for pure business logic (decision logic, calculations/mappings, state-machine
transitions, validation); **e2e** for real integrations only; **skip** what the compiler/ORM/DB
already guarantee. Name files by behavior, not ticket id; one spec per source file.

Run them green:
```bash
[ -n "$(cfg '.commands.typecheck')" ] && eval "$(cfg '.commands.typecheck')"
[ -n "$(cfg '.commands.test')" ] && eval "$(cfg '.commands.test')"   # or targeted: .commands.testFilter with {pkg}
```
Pure data-model / config / tooling work (no runtime logic) → tests can be skipped; **say so**.

## Step 4 — Local quality gate

Run the local review loop on the diff before handing to the human:
- **For UI features, start the dev server FIRST, in the background** (`<dev>` = `.commands.dev`, or
  docker compose as the feature needs) — it warms up while the reviews below run.
- Invoke the reviewers in **`.review.localReviewers`** (e.g. `/review` + `/codex`) **concurrently** —
  independent reads of the same diff. Fix high-confidence findings from both.
- **For UI features, browser QA is mandatory:** run **`.qa.qaSkill`** (`/qa`) against the (already
  warm) dev server, fix the bugs it surfaces, then re-verify. If the UI genuinely can't run locally,
  **do not skip silently** — STOP and report it as a blocker. **If `--e2e` was passed, skip this
  heuristic pass and run the scenario e2e in Step 4.5 instead** — one browser pass, not two.
- Re-run `<typecheck>` (+ tests) after fixes.

## Step 4.5 — Scenario browser e2e (only when `--e2e` is passed)

Opt-in deterministic happy-path verification. Walks **these exact user flows** end-to-end (unlike
the heuristic bug-hunt of Step 4). Skipped entirely unless `--e2e` is in `$ARGUMENTS`.

1. **Derive scenarios** — from the diff + the `<KEY>` ticket + the feature intent, write **2–4 key
   user flows**: the happy path plus the critical branches this change introduces (submit → success,
   invalid input → error, the cross-cutting API→UI→DB effect). Record them explicitly.
2. **Run** — against the already-warm local dev server:
   - **If `.qa.video.enabled` is true:** drive each scenario with the **recorder** so the run is
     captured to video. Write the scenario as JSON (steps: goto/fill/click/waitFor/expect/screenshot —
     see the recorder header) and run (pass `--gif` when the surface needs a PR gif):
     ```bash
     GIF=""; case "$(cfg '.qa.video.surface' 'context')" in both|pr-gif) GIF="--gif";; esac
     node ${CLAUDE_PLUGIN_ROOT}/lib/record-e2e.mjs <scenario>.json \
       --out-dir "$(cfg '.qa.video.dir' '.context/video')" \
       --format  "$(cfg '.qa.video.format' 'mp4')" $GIF \
       --base-url "<local dev url>" --max-seconds "$(cfg '.qa.video.maxSeconds' '90')"
     ```
     Exit **0** = all steps passed; **1** = a step failed (video still saved — use it to debug);
     **2** = Playwright unavailable → fall back to `.qa.browseSkill` for this scenario **without**
     video (never let a missing recorder block the e2e); **3** = scenario/usage error (bad flags or
     malformed scenario JSON) → **fix the scenario and re-run; do NOT fall back and do NOT mark it
     green.** For non-UI flows, assert the end effect (DB row / API response), not the page.
   - **Else** (`video` off): drive each scenario step-by-step with **`.qa.browseSkill`** (`/browse`):
     navigate → fill → click → assert state / screenshot.
3. **Fix-loop (the "tested" guarantee)** — a failing scenario → find the cause, fix the code
   (`<KEY>:` commit), `<typecheck>`, re-run that scenario. **Max 3 attempts** per scenario. Still
   failing → do **NOT** present the feature as green; carry the red e2e into the Step 5 handoff as a
   blocker (Autonomy contract).
4. **Report** — write the scenarios + per-step result + artifact paths (screenshots **and video**)
   to `.context/e2e-<KEY>.md`; it feeds the PR body and the Step 5 handoff. **Video surfacing** per
   `.qa.video.surface`:
   - `context` / `both` → the mp4 (or webm) is already under `.context/` (gitignored — perfect for
     chat) — reference it in the handoff so it renders in the Conductor chat (prefer the gif for
     guaranteed inline preview).
   - `pr-gif` / `both` → include the **gif** in the PR body. GitHub renders drag-dropped video only;
     an API-authored body cannot embed fresh video, so use the gif. Because `.context/` is
     gitignored, first copy the gif to a **committed** path (e.g. `docs/qa-media/<KEY>/<name>.gif`),
     commit it, and reference its raw URL
     (`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`); link the mp4/webm artifact
     path for full quality.

## Step 5 — Draft PR (pre-warm CI), then STOP for verification

Commit everything (`<KEY>:`). Then pre-warm the ship so **CI runs while the human verifies**:

1. Push the branch.
2. Open a **draft PR**: read `.rules.prTemplate`, populate **every** section (None/N/A allowed —
   context is hot now, write the real body; `/autoship` reuses it), write it to a temp file
   (`tmp=$(mktemp)`), then:
   `gh pr create --draft --base "$(cfg '.git.baseBranch')" --title "<KEY>: <summary>" --body-file "$tmp"`
   If a draft PR already exists (re-run), update it — push + `gh pr edit --body-file "$tmp"` — don't
   open a second one. `rm "$tmp"` afterwards.
3. CI starts automatically. **Do not post a manual review trigger.** The configured auto-reviewer
   (`.review.gate`) runs on ready PRs, not drafts by design — `/autoship` owns the review loop.

A draft PR **cannot be merged** — the no-ship guarantee holds. Do **not** mark it ready, merge, or deploy.

Then print a verification handoff and **stop**:

```
/autodev — ready for your verification (NOT shipped).
  Ticket:      <KEY>            (tracker: <.tracker.type>)
  Draft PR:    #<n> — NOT mergeable; CI running (auto-review runs after /autoship flips to ready)
  Plan:        <planDir>/<file>.md | (small task: TodoWrite inline)
  Built:       <one-line summary>
  Decisions/assumptions made: <bullets — the calls I made autonomously>
  Files:       <key files changed>
  Tests:       typecheck ✓ | <N unit> ✓ | <e2e ✓ | skipped: reason> | <localReviewers> ✓ | <UI: qa ✓ | →Step 4.5 (--e2e) | n/a non-UI>
  Browser e2e: <--e2e: N scenarios ✓ | M failed (BLOCKER) | not passed (flag off)>
  Video:       <path(s) under .context/ | gif in PR | n/a (video off / not --e2e)>
  Open questions / risks: <anything you'd want a human eye on>

  HOW TO VERIFY:
    - Run: <exact command / Conductor Run button>
    - Check: <what to click / curl, expected result>

  When it looks right → run /autoship to ship it to <base>
  (add --qa to auto-test the deployed build after the canary; --e2e for staging scenario e2e).
```

Do not continue past this gate. Wait for the user.
