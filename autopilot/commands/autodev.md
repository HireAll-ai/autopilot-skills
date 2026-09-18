---
description: Autonomous feature build — plan → implement → test → quality-review (+ opt-in --e2e browser e2e, optionally recorded to video), ending in a fully implemented & tested feature on the branch plus a DRAFT PR (CI pre-warmed; the configured auto-reviewer runs once /autoship flips it to ready), a live preview link and a written test plan, then STOPS for your verification. Does not ship — a draft PR is not mergeable. Project-independent: reads .claude/autopilot.config.json.
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

## Required skills (check once, up front)

Resolve these **once** at the start, not lazily mid-run — and never burn turns installing something
that isn't there. Two tiers:

- **Optional helpers — `superpowers:`** `writing-plans`, `test-driven-development`,
  `executing-plans`, `subagent-driven-development`. Nice when present; **if they don't resolve, just
  do the step directly** (Step 1 plans into a plan file / TodoWrite by hand; Step 3 writes the tests
  by hand). Do **not** install them mid-run and do **not** skip the underlying work.
- **Load-bearing — the skills named in config**: `.review.localReviewers` (Step 4), `.qa.qaSkill`
  (Step 4, required for UI features), `.qa.browseSkill` (Step 4.5, only with `--e2e`). `/run`
  optional. If one of these is configured but doesn't resolve, **say so in the handoff** — the gate
  it represents did not run.

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
- `<typecheck>` must be green **before each push and at the end of each logical batch of commits** —
  not after every single commit. On a ten-commit feature that is ten full type-checks for one signal;
  CI and Step 3/4 catch the rest. (Skip entirely if `.commands.typecheck` is empty.)

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
  docker compose as the feature needs) — it warms up while the reviews below run, and it stays
  up through Step 4.8 so the preview link you hand over actually answers.
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

## Step 4.8 — Live preview link + test plan (always)

The verification gate is only as good as what you hand over. Before Step 5, produce the two things
the human actually needs: **a URL they can click** and **a short test plan they can execute**.

### 1. Keep the app up, and get a URL that really answers

- The dev server from Step 4 should still be running. If it isn't (or Step 4 was skipped because the
  feature isn't UI-facing but still has a runnable surface), start `<dev>` = `.commands.dev` in the
  **background** now.
- **Read the URL the server actually printed** (its log / stdout) — never assume a port; dev servers
  fall through to the next free one. `.qa.preview.url` overrides when the bound URL isn't in the log
  (e.g. a sandbox-assigned port); if its value names an env var, resolve it at run time.
- Confirm it before you print it:
  `curl -fsS -o /dev/null -w '%{http_code}\n' "<url>"` → **must be 2xx/3xx.** A dead link is worse
  than no link — if it won't come up, that's a **blocker** in the handoff, not a link.
- **Leave the server running** when you stop at Step 5; the link has to work when the human clicks
  it. Put the exact restart command in the handoff for when the session is gone.

### 2. Land them signed in, on the changed surface

Link to **the thing you changed**, not the home page.
- If `.qa.preview.authPath` is set (a dev-only sign-in route, e.g. `/dev-login`), route through it —
  the human has no local password, so a bare link lands them on a login wall. Chain it to the target
  when that route takes a redirect param; otherwise hand over the two links in order.
- Walk the link yourself with `.qa.browseSkill` before handing it over.

### 3. Write the test plan → `.context/testplan-<KEY>.md`

Short and executable: **5–10 numbered checks**, each `do X → expect Y`, tied to what *this change*
claims. No QA boilerplate, and don't re-test what the unit tests already cover. Sections:

- **Open** — the preview link(s) + the restart command.
- **Checks** — happy path first, then the branches this change introduces (empty state, validation
  error, the other role/permission), then the neighbouring behaviour it could have regressed.
- **Not verified locally** — the honest list: 3rd-party callbacks, prod-only data, anything that
  needs a deploy. This is what to watch after `/autoship`.
- **If it looks wrong** — where to look first (that log line, that table, that endpoint).

### 4. Complex feature → a second, pre-loaded link

When reaching the state under test takes **more than ~3 manual steps** (sign in → navigate → create
a record → fill the form), or needs data a fresh local DB doesn't have, also hand over a **fast-path
link** that lands directly in that state. In order of preference:

1. **Deep links / query params the app already supports** — free, nothing to build.
2. **A scratch seed script** under `.context/` (gitignored, never committed): it creates the fixture
   against the local DB/API and prints the URL of what it made. Run it, verify the link, hand over
   both the link and the one-line re-seed command.
3. **Neither without new product code** → do **NOT** add prefill/backdoor code to the product just to
   make testing easier. Say so, and offer it as a follow-up the human can approve.

When several states are worth a look (invalid input, role B, the empty state), emit them as extra
links from the same seed script — cheap once the script exists.

*Invoked from `/autopilot` (no verification stop): still write the test plan — it doubles as the
post-deploy check list — but don't hold the dev server open.*

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

  TEST IT:
    Preview:    <url — signed in, landing on the feature | exact command/curl for non-UI work>
    Fast path:  <pre-seeded url + re-seed cmd | n/a: reachable in <3 steps | offered: needs product code>
    Test plan:  .context/testplan-<KEY>.md — <N> checks, first three:
                  1. <do X → expect Y>
                  2. <do X → expect Y>
                  3. <do X → expect Y>
    Server:     <running here — leave this session open> | restart: <dev> → <url>
    Not verified locally: <bullets | none>

  When it looks right → run /autoship to ship it to <base>
  (add --qa to auto-test the deployed build after the canary; --e2e for staging scenario e2e).
```

Do not continue past this gate. Wait for the user.
