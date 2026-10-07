---
description: Ship + land in one — flips the /autodev draft PR to ready (or opens a template-complete PR directly), rebases on the base branch only if it moved, loops the configured auto-reviewer to its pass bar, confirms required checks green, repo-aware merge, canary on the deployed env, optional --qa / --e2e (with video) automated checks, then moves the tracker ticket to the configured ship status. No human gates. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[deploy-url] [--qa] [--e2e] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent, AskUserQuestion, mcp__jira-server__get_issue, mcp__jira-server__get_transitions, mcp__jira-server__transition_issue
---

# /autoship — ship → clean → merge → deploy → ship-status (autonomous)

Run this when the code is **done and you've verified it** (typically after `/autodev`). It flips the
`/autodev` draft PR to ready (or opens the PR directly, template-complete), rebases on the base
branch **only if it moved**, loops the configured auto-reviewer + fixes until its pass bar, confirms
the required checks are green, merges respecting branch protection, verifies the deploy with a light
canary (optionally an automated QA / e2e pass), then moves the tracker ticket to the configured ship
status. **No human gates.**

**Project-independent.** All project facts come from `.claude/autopilot.config.json` (Step 0.0).
The command body hardcodes nothing.

Arguments (optional, any order):
- deploy URL — for canary (and `--qa`/`--e2e`). If omitted, use `.deploy.urls.client` (else the first
  `.deploy.urls` entry). The human-readable source of truth is `.deploy.docsRef`.
- `--qa` — after a clean canary, run an automated **report-only** QA pass (`.qa.qaOnlySkill`) against
  the deployed build, scoped to the flows this PR touched. A real critical/high regression from this
  ship **blocks the ticket move** (Step 6).
- `--e2e` — after a clean canary, run **scenario-based browser e2e** (`.qa.browseSkill`, Step 5.6)
  against the deployed build; with `.qa.video.enabled` the walk is **recorded to video**. Post-merge,
  so **report-only** — a failure caused by this ship surfaces a revert / fix-forward choice and
  **blocks the ticket move**; fixes are follow-up PRs, never local edits. Independent of `--qa`.
- `--reconfigure` — re-run the config interview (Step 0.0).
- `--preloaded` — internal, passed by `/autopilot`: Step 0.0 already ran and the config is in context.

## Step 0.0 — Init check + load project config (ALWAYS FIRST, one call)

Skip when `$ARGUMENTS` has `--preloaded` (`/autopilot` already ran this; the config is in context).

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" load; echo "rc=$?"     # add --reconfigure if passed
```
- **rc=0** → stdout **is** the config — read once, keep it in context.
- **rc=4** → `NOT_INITIALIZED` → **STOP.** Tell the user to run **`/autopilot:init`** first (gstack,
  config, factory scaffold, DESIGN.md + docs bootstrap), then re-run this command.
- **rc=3** → no config (or `--reconfigure`): Read `${CLAUDE_PLUGIN_ROOT}/lib/config-interview.md` and
  run it. `/autoship` needs the tracker/review/deploy sections populated to run at all.
- **rc=2 / other** → hard loader error on stderr (commonly: `jq` missing) → surface it, **STOP**.

**Shell state does not persist between Bash calls** — substitute config values literally into each
command rather than relying on variables from an earlier call (`<merge-sha>` included: once captured
in Step 4, write it into later commands verbatim).

Placeholders resolve from config: `<base>` = `.git.baseBranch`, `<KEY>` = a `<keyPrefix>-NNN` key
(upper-case; found in a branch name case-insensitively — `pos-42-…` carries `POS-42`),
`<checks>` = `.git.protection.requiredChecks`, `<mergeStrategy>` = `.git.mergeStrategy`, etc.
**`<subject>`** = a commit subject or PR title in `.git.commitStyle` (absent = `key-prefix`):
`key-prefix` → `<KEY>: <what + why>`; `conventional` → `type(scope): summary` (Conventional Commits
1.0, imperative, ≤72 chars, no key in the subject — it goes in a `Refs: <KEY>` commit trailer and a
`Ticket: <KEY>` line in the PR body). The PR title is the squash subject, so it follows the same rule.
**`<typecheck>`** = `"${CLAUDE_PLUGIN_ROOT}/lib/typecheck.sh"` — passes trivially when
`.commands.typecheck` is empty and is a **no-op on a working tree that already passed** (cached by
tree hash), so every gate below that re-asserts it costs nothing unless the code changed.

**Long waits go in the background.** CI watches, merge-queue waits and deploy verification routinely
outlive the Bash tool's 10-minute foreground cap: run them with `run_in_background: true` — you are
re-invoked when they exit — and never `sleep`-poll in the foreground.

## Required skills (verify installed before running)
Check each **once**, up front — a skill that doesn't resolve has a defined fallback, so never stall
mid-run hunting for one:
- **`.review.skill`** (e.g. `greploop`) — Step 2, when `.review.gate != none`. **Optional**: when the
  key is absent or the skill doesn't resolve, Step 2.1 drives the loop inline with `gh`.
- **`.deploy.canarySkill`** (e.g. `/canary`) — Step 5.2. Missing → `curl` the changed surface directly.
- **`.qa.qaOnlySkill`** — Step 5.5 (only with `--qa`). **`.qa.browseSkill`** — Step 5.6 (only with
  `--e2e`). Missing → say the optional pass was skipped; never silently claim it ran.

## Non-negotiable rules (from config + the repo's own docs `.rules.docs`)

- **Merge with `<mergeStrategy>`**, base branch `<base>`.
- **Branch protection** is read from config `.git.protection`: required checks `<checks>`; threads
  must resolve when `requireThreadResolution`; **`strict`** decides whether a behind branch still
  merges (when false, being up-to-date is **not** a merge requirement); `requiredApprovals`;
  `adminBypassAllowed` (true only when `enforce_admins` is off) permits `--admin` **once the required
  checks are independently confirmed green**. Any auto-reviewer pass bar (`.review.passBar`) is a
  self-imposed quality gate **above** protection, kept deliberately.
- **PR template mandatory** — `.rules.prTemplate`, populate every section (None/N/A allowed), never replace it.
- **Ticket key** — if `.tracker.keyRequired`, every change carries `<KEY>` (branch, and the commit /
  PR per `<subject>` — under `conventional` that's the `Refs:` trailer and the `Ticket:` line). Don't invent one.
- **Move the ticket to `.tracker.shipStatus`** as the final step on a fully successful ship (Step 6);
  running `/autoship` IS the explicit go-ahead. Skip + report if the ship stopped short.
- **`<typecheck>` must pass before any commit** (`.commands.typecheck`).
- Merge to `<base>` triggers the deploy per `.deploy` (when `.deploy.autoDeploys`). Never deploys on a
  red required check. **Whether that deploy actually landed is proven in Step 5 via
  `.deploy.verify`** — with an external builder, neither a green push-CI run nor a 200 from
  `.deploy.healthcheck` is evidence (the old build answers both).

## Hard gate — NEVER merge unless ALL hold

1. Auto-reviewer at `.review.passBar` AND **zero** unresolved review threads (when `.review.gate != none`).
2. `<typecheck>` exits 0.
3. Full CI rollup green — `gh pr checks <PR>` all `pass` (auto-reviewer included).
4. PR body follows `.rules.prTemplate`, no empty required sections.
5. Branch, PR title or PR body (`Ticket: <KEY>`) carries `<KEY>` (when `.tracker.keyRequired`).

If any fails and can't be auto-fixed in the loop, **STOP and report** — do not merge.

---

## Step 0 — Preflight

```bash
gh auth status >/dev/null 2>&1 || echo "gh not authenticated"
git rev-parse --abbrev-ref HEAD
git log --oneline "origin/<base>..HEAD" | head        # confirm there are commits to ship
gh pr view --json number,isDraft,url 2>/dev/null || true   # /autodev usually left a draft PR
```
If `.tracker.keyRequired` and neither the branch nor an existing PR (title, `Ticket:` line) carries
`<KEY>`, **STOP** and ask for the ticket. Capture the key — Step 6 transitions it.

## Step 0.5 — Commit stragglers; rebase on base only if it moved

If `.git.protection.strict` is **false**, a slightly-behind branch still merges — don't force a sync
every run (an unconditional rebase throws away `/autodev`'s pre-warmed CI). Do the always-safe part
(commit stragglers); rebase **only** when the base actually moved:

1. **Clean the tree** — `git status --porcelain`. Straggling work → run `<typecheck>` first
   (type-check must pass before *any* commit), then commit it (`<subject>`). A dirty tree also blocks the rebase.
2. Rebase only if behind, then publish:
```bash
git fetch origin "<base>"
git merge-base --is-ancestor "origin/<base>" HEAD && echo "already current — no rebase" || {
  git rebase "origin/<base>" && "${CLAUDE_PLUGIN_ROOT}/lib/typecheck.sh"
}
git push --force-with-lease -u origin HEAD   # no-op if nothing changed (keeps pre-warmed CI); -u: the
                                             # branch may never have been pushed (no /autodev run)
```
The pre-warm survives **only** when step 1 found nothing to commit and no rebase happened (then
`git push` is a true no-op). Otherwise CI/review correctly re-run on the new HEAD — intended, not
wasted. Unresolvable rebase conflicts → **STOP and report**.

## Step 1 — Ship the PR (direct, repo-aware)

Ship directly — no full local test run (CI is the authoritative gate; locally only `<typecheck>`
must be green):
1. `<typecheck>` must pass (tree already committed/rebased/pushed by Step 0.5).
2. **Draft PR exists** (`/autodev` pre-warm)? Verify its body still matches `.rules.prTemplate`
   (every required section, None/N/A allowed) and still describes the final diff — if not, rebuild
   into a temp file (`tmp=$(mktemp)`), `gh pr edit <PR> --body-file "$tmp"`, `rm "$tmp"`. Then flip:
   `gh pr ready <PR>`.
3. **No PR yet?** Populate the template into a temp file (plus the `Ticket: <KEY>` line under
   `conventional`), `gh pr create --base "<base>" --title "<subject>" --body-file "$tmp"`, `rm "$tmp"`.

Capture the PR number (`gh pr view --json number,url`).

## Step 2 — Review + CI loop (max 5 outer iterations)

Skip Step 2.1 entirely when `.review.gate == none`. Otherwise repeat until the hard gate holds:

1. **Auto-reviewer → pass bar** — flipping to ready (Step 1) kicks off `.review.gate`'s review; every
   push re-runs it. Drive the loop (poll, fix actionable comments, resolve threads, push, re-review)
   until **`.review.passBar` + 0 unresolved threads**. If a manual re-trigger is ever needed, use
   `.review.mention`.
   - **`.review.skill` set and resolving** → invoke it (e.g. `greploop`); it owns the loop.
   - **Otherwise — drive it inline, don't stall.** Poll the review with
     `gh pr view <PR> --json reviewDecision,comments` and
     `gh api "repos/{owner}/{repo}/pulls/<PR>/comments" --jq '.[] | {id,path,line,body}'`; fix what is
     actionable, reply on the thread with the fixing commit (or argue it down), push, wait for the
     re-review (poll it in the background, not with a foreground `sleep`). Resolve threads with the GraphQL `resolveReviewThread` mutation — unresolved threads
     block the merge when `.git.protection.requireThreadResolution`.
2. **One CI confirmation per push.** Every push re-triggers the required checks `<checks>`. After the
   loop's latest push, watch the rollup **once** — **in the background** (`run_in_background: true`;
   CI often runs past the 10-minute foreground cap), then read the result in the foreground:
   ```bash
   gh pr checks <PR> --watch --interval 30         # background; you're re-invoked when it exits
   gh pr checks <PR> --json name,state,bucket      # foreground, after
   ```
   - A required check **fails** → `gh run view --log-failed`, then classify:
     - **Infra flake** (broken pipe / transient SSH / runner death — nothing in the code):
       `gh run rerun --failed`, re-watch — max **2 consecutive** infra reruns; a 3rd → **STOP and
       report**. Code didn't change → do **NOT** restart the review loop.
     - **Real failure** → fix the cause, commit (`<subject>`), push, back to 1. Don't paper over red.
   - **Any other visible check** non-green (bucket ≠ `pass`/`skipping`) → investigate and fix. The
     Step 4 hard-gate re-assertion refuses `--admin` while any check is non-green.
   - **Local gate still applies:** `<typecheck>` exits 0 before any commit.
3. **Stuck score:** every comment fixed + thread resolved but the score sits below `.review.passBar`
   → rebase on base (Step 0.5) + **one** re-review — a clean rebase is what lifts a stuck score on
   big multi-file PRs.
4. **Before breaking, `<typecheck>` the final HEAD** (CI's type-check may be advisory), fail → fix →
   commit → push → back to 1. Then hard gate satisfied → break. After 5 outer iterations without
   convergence, **STOP** and report.

## Step 3 — Mergeable check (conflict only when base isn't strict)

```bash
gh pr view <PR> --json mergeStateStatus,mergeable
```
If `.git.protection.strict` is false, a plain **`BEHIND`** branch still merges — do **not**
`gh pr update-branch` just to clear it (fires a second full CI run for nothing). Act only on a real blocker:
- `mergeable: false` / `CONFLICTING` → rebase (Step 0.5), then **re-run the full Step 2 loop** (a
  rebase yields a new tree). Proceed only once the hard gate holds again.
- Otherwise (incl. a plain `BEHIND`) → a quick **semantic-overlap check** — a non-textual conflict
  (a moved API / schema / shared-package dependency) can break the merged tree even with green checks:
  ```bash
  git fetch origin "<base>" -q
  git diff --name-only "HEAD...origin/<base>"   # what moved on base since this branch's base
  ```
  If that delta touches **shared/contract surface this diff depends on** (`packages/*`, DB
  migrations/entities, an API contract, `package.json`/lockfile) → **rebase + re-run Step 2**, then
  merge. Clearly unrelated → straight to merge.

## Step 4 — Merge (autonomous, repo-aware)

Re-confirm the hard gate, then merge with the configured strategy (`--delete-branch` only when
`.git.deleteBranchOnMerge` is true):
```bash
gh pr merge <PR> --<mergeStrategy> [--delete-branch]
```
**Merge queue** — when `.git.mergeQueue` is true, or the direct merge is rejected because the base
requires a merge queue: enqueue instead, `gh pr merge <PR> --auto [--delete-branch]` (the queue
applies its own strategy), then wait for it **in the background**:
```bash
for i in $(seq 1 90); do   # ≤45 min
  S=$(gh pr view <PR> --json state,autoMergeRequest --jq '"\(.state) \(.autoMergeRequest != null)"')
  case "$S" in MERGED*) echo merged; exit 0;; "OPEN false") echo "dropped from the queue"; exit 1;; esac
  sleep 30
done; echo "still queued after 45 min"; exit 1
```
Dropped from the queue → read why (`gh pr checks <PR>`, the queue's run), treat it like a red check in
Step 2. Never `--admin` around a queue.

If branch protection rejects a direct merge **despite green CI**, gate the bypass behind an explicit
assertion — **only if `.git.protection.adminBypassAllowed` is true** (otherwise STOP and report:
cannot bypass protection) — re-query every check and refuse `--admin` unless all are terminally green:
```bash
NOT_GREEN=$(gh pr checks <PR> --json name,state,bucket \
  | jq '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | length')
if [ "$NOT_GREEN" = "0" ]; then gh pr merge <PR> --<mergeStrategy> [--delete-branch] --admin
else echo "ABORT: $NOT_GREEN check(s) not green — refusing --admin"; fi
```
A worktree-cleanup error from `--delete-branch` is harmless.

**Capture the merge SHA** — Step 5 needs it (write it into later commands verbatim as `<merge-sha>`):
```bash
gh pr view <PR> --json mergeCommit --jq '.mergeCommit.oid // "ABORT: no merge commit SHA — did the merge land?"'
```

## Step 5 — Verify the deploy (light canary)

Skip this step if `.deploy.trigger == none`.

**What counts as evidence.** Only a signal that names the running build proves the merge is live.
A green push-triggered CI run on `<base>` does **not**, unless that run is itself the deployer — with
an external builder (Coolify, Vercel, Render, Fly) the build happens off GitHub, invisible to
`gh run`, and `.deploy.healthcheck` keeps answering **from the previous build** until the swap. Take
the mode from `.deploy.verify.mode`; when absent, infer `github-run` if `.deploy.trigger ==
"github-action"`, else `none`.

### 5.1 — Confirm the merge is live

One script covers every mode. It polls for up to `.deploy.verify.timeoutSeconds` (default 600) and
may then watch runs — **run it in the background** (`run_in_background: true`); you're re-invoked
when it exits:
```bash
"${CLAUDE_PLUGIN_ROOT}/lib/verify-deploy.sh" <merge-sha>
```

| exit | meaning | do |
|---|---|---|
| **0** | `VERIFIED` — `build-id`: the endpoint reports `<merge-sha>`; `github-run`: the deploy run(s) for `<merge-sha>` went green | continue to the canary |
| **1** | `BROKEN` — a deploy run failed, or the build-id endpoint was unreachable the whole window | **hard STOP**: skip 5.5 / 5.6 / 6, surface it, offer the **revert recipe** |
| **10** | `UNVERIFIED` — old build still answering at the deadline, no push run observed, or mode `none` | **unverified** (below) |
| **12** | `COMMIT_UNKNOWN` — the endpoint answers but its commit reads `unknown`/empty (the build arg never arrived — **not** a failed deploy) | if it printed a `restartedAt` **after** the merge time, count it as deployed and say the evidence was the restart, not the commit; else **unverified** |
| **2** | config/usage error (e.g. `build-id` without `buildIdUrl`) | fix the config, re-run |

`github-run` only counts runs triggered by the **push** of `<merge-sha>` to `<base>` (never "the
latest run" or a same-SHA manual run), filtered to `.deploy.verify.workflow` when set. Without it,
**every** push run for that SHA (CI, lint, deploy) must go green — set `workflow` so an unrelated
red lint job can't masquerade as a broken deploy.

**mode `none`** never prints "deploy verified". *(Worth fixing: a two-line `/version` route returning
the commit baked in at build time turns it into `build-id`.)*

**Unverified** (any mode) is **not a failure** — the ship **landed**, only its automated confirmation
is pending. Do **NOT** revert. Still run the canary, and say plainly in Step 6 that the deploy is
unverified and the operator should re-check. It does not by itself block Step 6.

**Revert recipe** — Step 4 may have deleted the branch; branch fresh from the base:
```bash
git fetch origin "<base>"
git switch -c "revert-<KEY>-deploy" "origin/<base>"
git revert --no-edit <merge-sha>
git push -u origin HEAD   # then open a PR --base "<base>" with the populated template
```

### 5.2 — Light canary

A **light** canary that **exercises what this PR changed** — and, when 5.1 came back unverified,
this is the *only* evidence, so make it assert something the new build alone can satisfy:
- **UI change** → invoke **`.deploy.canarySkill`** against the deploy URL (arg, else
  `.deploy.urls.client`, else the first `.deploy.urls` entry) for a quick page-load smoke of the
  touched flow.
- **Backend / API / worker change** → hit the *shipped behavior* directly: `curl` the changed
  endpoint and assert the response, or assert the worker/queue effect. Don't collapse to "is it up" —
  a new route answering 401/200 while a bogus route answers 404 proves the new server build is live.

Keep it **light**. A broken page / failed assertion / console-error wall = a real problem → surface it
+ offer the revert recipe (don't auto-revert). **A real canary problem also blocks 5.5/5.6/6.**

## Step 5.5 — Optional automated QA (`--qa`)

Only with `--qa` (else skip silently). Code is merged — **report-only** (`.qa.qaOnlySkill`); fixes are follow-up PRs:
- Run **`.qa.qaOnlySkill`** against the deploy URL in a **subagent** (`Agent`; keeps its long body and
  transcript out of this context), quick tier (critical/high), scoped to the flows this PR touched;
  it returns findings only.
- **critical/high regression caused by this ship** → **blocks Step 6**; report + offer revert or
  fix-forward. medium/low or pre-existing → include, don't block.

## Step 5.6 — Optional scenario browser e2e (`--e2e`)

Only with `--e2e` (else skip silently). Otherwise **Read `${CLAUDE_PLUGIN_ROOT}/lib/e2e.md`** and
follow its **deployed** mode against the deploy URL: 2–4 scenarios from the diff + `<KEY>` + PR body,
recorded when `.qa.video.enabled`, **report-only** (merged code — fixes are follow-up PRs). A scenario
failing **because of this ship** → **blocks Step 6** + offer revert or fix-forward; pre-existing
breakage → include, don't block. Write the run into the final report.

## Step 6 — Report + move the ticket to the ship status

Print the report:
```
/autoship complete.
  PR:        #<n> — <title>
  Review:    <gate> <iters>, <passBar>, <N> resolved   (or: gate=none)
  CI:        green (<checks>)
  Merge:     <mergeStrategy> <SHA> (direct | --admin)
  Deploy:    <env> — <verified <SHA> via <mode> | UNVERIFIED: <why>>, canary <ok | issues>   (or: deploy=none)
  QA:        <--qa not passed | ok | N findings (blocking: yes/no)>
  E2E:       <--e2e not passed | N scenarios ok | M failed (blocking: yes/no)>
  Video:     <path(s) | gif in PR | n/a>
```
Then **transition the ticket `<KEY>` to `.tracker.shipStatus`** — running `/autoship` is the explicit
go-ahead, so this step **acts** (doesn't just remind). Skip entirely when `.tracker.type == none`.
Via the configured tracker MCP (`.tracker.mcp`, e.g. `mcp__jira-server__*`):
1. **Already there?** Read current status (`get_issue`). If it equals `.tracker.shipStatus`, **skip**
   (`already <shipStatus>`) so a re-run doesn't bounce it.
2. `get_transitions` for `<KEY>`. If a transition whose `to` matches `.tracker.shipStatus` is offered → `transition_issue`. Done.
3. Else, if a status in `.tracker.shipStatusVia` is offered (board gates the ship status behind it):
   `transition_issue` to it, then call `get_transitions` **AGAIN**. **Only if** the re-fetched list now
   contains the ship-status transition → take it. If still not offered, **STOP** — never call
   `transition_issue` with a name/id absent from the latest `get_transitions`; print `<KEY> → <via>
   (no <shipStatus> transition from here — move it manually)`.
4. Print the final status reached.

**Guards — only transition on a clean ship:** Step 4 actually merged (real SHA) AND Step 5 canary
didn't flag a real problem AND (if `--qa`) no blocking regression AND (if `--e2e`) no scenario failing
because of this ship. Ship stopped short → **DO NOT transition**; report the blocker. Tracker MCP
unavailable / key not tracked → **skip** with a one-line note, don't fail the run.

---

### Notes
- Pairs with `/autodev` (plan→build→test→draft-PR→verify-gate). For the no-verification single-shot
  variant see `/autopilot` (autodev + autoship back-to-back, staging QA ON by default).
- Intentionally uses repo-aware `--admin`/`update-branch` (gated on config) so it never stalls on
  strict protection. The ticket move (Step 6) is the one place `/autoship` writes to the tracker.
- Project-independent: all facts from `.claude/autopilot.config.json`. To share the commands
  themselves across repos, install the `autopilot` plugin: `claude plugin marketplace add HireAll-ai/autopilot-skills`.
