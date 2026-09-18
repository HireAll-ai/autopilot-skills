---
description: Ship + land in one — flips the /autodev draft PR to ready (or opens a template-complete PR directly), rebases on the base branch only if it moved, loops the configured auto-reviewer to its pass bar, confirms required checks green, repo-aware merge, canary on the deployed env, optional --qa / --e2e (with video) automated checks, then moves the tracker ticket to the configured ship status. No human gates. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[deploy-url] [--qa] [--e2e] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, mcp__jira-server__get_issue, mcp__jira-server__get_transitions, mcp__jira-server__transition_issue
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
- **rc=0** → loaded. **rc=3 (or `--reconfigure`)** → run the first-run interview (see `/autodev`
  Step 0.0), write `.claude/autopilot.config.json`, `git add` + `"$CFG" validate`. `/autoship`
  needs the tracker/review/deploy sections populated to run at all.
- **rc=2 (or any other code)** → loader hard error (jq missing, unreadable config, bad subcommand):
  read `/tmp/autopilot.cfg.err`, surface it (commonly: install `jq`), and **STOP**.

Placeholders below resolve from config: `<base>` = `.git.baseBranch`, `<KEY>` = a `<keyPrefix>-NNN`
key, `<checks>` = `.git.protection.requiredChecks`, `<mergeStrategy>` = `.git.mergeStrategy`, etc.

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
- **Ticket key** — if `.tracker.keyRequired`, every change carries `<KEY>` (branch/commit prefix). Don't invent one.
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
5. Branch / PR carries `<KEY>` (when `.tracker.keyRequired`).

If any fails and can't be auto-fixed in the loop, **STOP and report** — do not merge.

---

## Step 0 — Preflight

```bash
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated"; exit 1; }
BASE=$(cfg '.git.baseBranch')
git rev-parse --abbrev-ref HEAD
git log --oneline "origin/$BASE..HEAD" | head        # confirm there are commits to ship
gh pr view --json number,isDraft,url 2>/dev/null || true   # /autodev usually left a draft PR
```
If `.tracker.keyRequired` and the branch has no `<KEY>`, **STOP** and ask for the ticket. Capture the key — Step 6 transitions it.

## Step 0.5 — Commit stragglers; rebase on base only if it moved

If `.git.protection.strict` is **false**, a slightly-behind branch still merges — don't force a sync
every run (an unconditional rebase throws away `/autodev`'s pre-warmed CI). Do the always-safe part
(commit stragglers); rebase **only** when the base actually moved:

1. **Clean the tree** — `git status --porcelain`. Straggling work → run `<typecheck>` first
   (type-check must pass before *any* commit), then commit it (`<KEY>:`). A dirty tree also blocks the rebase.
2. Rebase only if behind, then publish:
```bash
git fetch origin "$BASE"
git merge-base --is-ancestor "origin/$BASE" HEAD && echo "already current — no rebase" || {
  git rebase "origin/$BASE" && eval "$(cfg '.commands.typecheck')"
}
git push --force-with-lease   # no-op if nothing changed (keeps pre-warmed CI); else publishes
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
3. **No PR yet?** Populate the template into a temp file, `gh pr create --base "$BASE" --title
   "<KEY>: <summary>" --body-file "$tmp"`, `rm "$tmp"`.

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
     re-review. Resolve threads with the GraphQL `resolveReviewThread` mutation — unresolved threads
     block the merge when `.git.protection.requireThreadResolution`.
2. **One CI confirmation per push.** Every push re-triggers the required checks `<checks>`. After the
   loop's latest push, watch the rollup **once**:
   ```bash
   gh pr checks <PR> --watch --interval 20
   gh pr checks <PR> --json name,state,bucket
   ```
   - A required check **fails** → `gh run view --log-failed`, then classify:
     - **Infra flake** (broken pipe / transient SSH / runner death — nothing in the code):
       `gh run rerun --failed`, re-watch — max **2 consecutive** infra reruns; a 3rd → **STOP and
       report**. Code didn't change → do **NOT** restart the review loop.
     - **Real failure** → fix the cause, commit (`<KEY>:`), push, back to 1. Don't paper over red.
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
  git fetch origin "$BASE" -q
  git diff --name-only "HEAD...origin/$BASE"   # what moved on base since this branch's base
  ```
  If that delta touches **shared/contract surface this diff depends on** (`packages/*`, DB
  migrations/entities, an API contract, `package.json`/lockfile) → **rebase + re-run Step 2**, then
  merge. Clearly unrelated → straight to merge.

## Step 4 — Merge (autonomous, repo-aware)

Re-confirm the hard gate, then merge with the configured strategy:
```bash
STRAT=$(cfg '.git.mergeStrategy'); DEL=""; [ "$(cfg '.git.deleteBranchOnMerge')" = "true" ] && DEL="--delete-branch"
gh pr merge <PR> --"$STRAT" $DEL
```
If branch protection rejects it **despite green CI**, gate the bypass behind an explicit assertion —
re-query every check and refuse `--admin` unless all are terminally green, **and only if
`.git.protection.adminBypassAllowed` is true**:
```bash
if [ "$(cfg '.git.protection.adminBypassAllowed')" = "true" ]; then
  NOT_GREEN=$(gh pr checks <PR> --json name,state,bucket \
    | jq '[.[] | select(.bucket != "pass" and .bucket != "skipping")] | length')
  if [ "$NOT_GREEN" = "0" ]; then
    gh pr merge <PR> --"$STRAT" $DEL --admin
  else echo "ABORT: $NOT_GREEN check(s) not green — refusing --admin"; exit 1; fi
else echo "ABORT: adminBypassAllowed=false — cannot bypass protection"; exit 1; fi
```
A worktree-cleanup error from `--delete-branch` is harmless.

**Capture the merge SHA** — Step 5 needs it to watch the right base run:
```bash
MERGE_SHA=$(gh pr view <PR> --json mergeCommit --jq '.mergeCommit.oid')
[ -n "$MERGE_SHA" ] || { echo "ABORT: no merge commit SHA — did the merge land?"; exit 1; }
echo "merged as $MERGE_SHA"
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

**mode `build-id`** — poll the build-id endpoint until it reports `$MERGE_SHA`:
```bash
VURL=$(cfg '.deploy.verify.buildIdUrl'); VJQ=$(cfg '.deploy.verify.buildIdJq' '.commit')
DEADLINE=$(( $(date +%s) + $(cfg '.deploy.verify.timeoutSeconds' '600') )); LIVE=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  LIVE=$(curl -fsS --max-time 10 "$VURL" | jq -r "$VJQ // empty" 2>/dev/null || true)
  [ "$LIVE" = "$MERGE_SHA" ] && break
  sleep 15
done
```
- `LIVE == $MERGE_SHA` → **deployed, verified.** Continue to the canary.
- Endpoint reachable but the commit reads `unknown`/empty (the build arg never arrived — it is **not**
  a failed deploy): if `.deploy.verify.restartedAtJq` is set, accept a restart **after** the merge
  time as deployed and say the evidence was the restart, not the commit. Otherwise → **unverified**
  (below).
- Endpoint **unreachable for the whole window** → the env is down at the API level → **hard STOP**:
  skip 5.5 / 5.6 / 6, surface it, offer the **revert recipe**.
- Still the old commit at the deadline → **unverified** (below). The builder may just be slow.

**mode `github-run`** — the deploy *is* a GitHub Actions run, so watch the push run for `$MERGE_SHA`
(not "the latest run", not a same-SHA manual run):
```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner); RUN_ID=""
for i in $(seq 1 30); do   # ~10 min: the push run can queue behind earlier deploys
  RUN_ID=$(gh api "repos/$REPO/actions/runs?head_sha=$MERGE_SHA&event=push&branch=$BASE&per_page=20" \
    --jq '[.workflow_runs[]][0].id // empty')
  [ -n "$RUN_ID" ] && break; sleep 20
done
```
Run found → `gh run watch "$RUN_ID" --exit-status`: non-zero → env **broken** for this merge → **hard
STOP** (skip 5.5 / 5.6 / 6, offer the revert recipe); exit 0 → **deployed, verified**. Run never
found → **unverified** (below).

**mode `none`** — nothing can confirm the build. Go straight to the canary and report the deploy as
**unverified**; never print "deploy verified". *(Worth fixing: a two-line `/version` route returning
the commit baked in at build time turns this into `build-id`.)*

**Unverified** (any mode) is **not a failure** — the ship **landed**, only its automated confirmation
is pending. Do **NOT** revert. Still run the canary, and say plainly in Step 6 that the deploy is
unverified and the operator should re-check. It does not by itself block Step 6.

**Revert recipe** — Step 4 may have deleted the branch; branch fresh from the base:
```bash
git fetch origin "$BASE"
git switch -c "revert-<KEY>-deploy" "origin/$BASE"
git revert --no-edit "$MERGE_SHA"
git push -u origin HEAD   # then open a PR --base "$BASE" with the populated template
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
- Invoke **`.qa.qaOnlySkill`** against the deploy URL, quick tier (critical/high), scoped to the
  flows this PR touched.
- **critical/high regression caused by this ship** → **blocks Step 6**; report + offer revert or
  fix-forward. medium/low or pre-existing → include, don't block.

## Step 5.6 — Optional scenario browser e2e (`--e2e`)

Only with `--e2e` (else skip silently). Merged + deployed, so **report-only** — fixes are follow-up PRs:
- **Derive scenarios** — 2–4 key user flows from the diff + `<KEY>` + PR body.
- **Run** each against the **deploy URL**:
  - `.qa.video.enabled` → use the recorder for video evidence (pass `--gif` when the surface needs a PR gif):
    ```bash
    GIF=""; case "$(cfg '.qa.video.surface' 'context')" in both|pr-gif) GIF="--gif";; esac
    node ${CLAUDE_PLUGIN_ROOT}/lib/record-e2e.mjs <scenario>.json \
      --out-dir "$(cfg '.qa.video.dir' '.context/video')" --format "$(cfg '.qa.video.format' 'mp4')" $GIF \
      --base-url "<deploy url>" --max-seconds "$(cfg '.qa.video.maxSeconds' '90')"
    ```
    exit **2** (Playwright unavailable) → fall back to `.qa.browseSkill` without video; exit **3**
    (scenario/usage error) → fix the scenario JSON and re-run (don't fall back, don't mark green).
    For non-UI flows, assert the end effect (API response / DB-visible result).
  - else → drive with **`.qa.browseSkill`** step-by-step.
- **Findings:** a scenario failing **because of this ship** → **blocks Step 6**; report the failing
  step + screenshot/video + offer revert or fix-forward. Pre-existing breakage → include, don't block.
- Surface video per `.qa.video.surface`: mp4/webm under `.context/` (gitignored) for the chat; for a
  PR/PR-comment gif, GitHub can't embed API-uploaded video, so copy the gif to a **committed** path
  (e.g. `docs/qa-media/<KEY>/<name>.gif`) and reference its raw URL. Write the run into the final report.

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
