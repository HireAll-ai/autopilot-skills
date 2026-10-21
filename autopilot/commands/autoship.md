---
description: Ship + land in one — every PR this chat opened, in any repo (or only the PRs you name) — re-checks the ticket is still wanted, flips the /autodev draft PR to ready (or opens a template-complete PR directly), rebases on the base branch only if it moved, loops the configured auto-reviewer to its pass bar, confirms required checks green, repo-aware merge, canary on the deployed env, optional --qa / --e2e (with video) automated checks, then moves the tracker ticket to the configured ship status. No human gates. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[PR …] [deploy-url] [--qa] [--e2e] [--video] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent, AskUserQuestion, mcp__jira-server__get_issue, mcp__jira-server__get_transitions, mcp__jira-server__transition_issue, mcp__backlog__get_issue, mcp__backlog__update_issue, mcp__backlog__add_comment, mcp__backlog__list_projects, mcp__backlog__list_issues, mcp__backlog__create_issue, mcp__backlog__propose_issues, mcp__backlog__attach_video
---

# /autoship — ship → clean → merge → deploy → ship-status (autonomous)

Run this when the code is **done and you've verified it** (typically after `/autodev`). It flips the
`/autodev` draft PR to ready (or opens the PR directly, template-complete), rebases on the base
branch **only if it moved**, loops the configured auto-reviewer + fixes until its pass bar, confirms
the required checks are green, merges respecting branch protection, verifies the deploy with a light
canary (optionally an automated QA / e2e pass), then moves the tracker ticket to the configured ship
status. **No human gates.**

**Every PR this chat opened ships — not just the current repo's.** A chat often spans repos (an API
change here, its client in a sibling repo); Step 0 collects all of them and each one runs Steps
0.5–5 in its own checkout, under its own repo's config.

**Project-independent.** All project facts come from `.claude/autopilot.config.json` (Step 0.0).
The command body hardcodes nothing.

Arguments (optional, any order):
- PR refs — `#277`, `owner/repo#12` or a PR URL: ship **only** these (a bare `#n` is the cwd repo's).
  Omitted → every PR this chat opened (Step 0).
- deploy URL — for canary (and `--qa`/`--e2e`) of the cwd repo's PR. If omitted, and for PRs in other
  repos, use that repo's `.deploy.urls.client` (else the first `.deploy.urls` entry). The
  human-readable source of truth is `.deploy.docsRef`.
- `--qa` — after a clean canary, run an automated **report-only** QA pass (`.qa.qaOnlySkill`) against
  the deployed build, scoped to the flows this PR touched. A real critical/high regression from this
  ship **blocks the ticket move** (Step 6).
- `--e2e` — after a clean canary, run **scenario-based browser e2e** (`.qa.browseSkill`, Step 5.6)
  against the deployed build; with `.qa.video.enabled` the walk is **recorded to video**. Post-merge,
  so **report-only** — a failure caused by this ship surfaces a revert / fix-forward choice and
  **blocks the ticket move**; fixes are follow-up PRs, never local edits. Independent of `--qa`.
- `--video` — record that e2e walk to video even when `.qa.video.enabled` is off; implies `--e2e`.
  With tracker `backlog` and a `<KEY>`, each video is also attached to the issue.
- `--reconfigure` — re-run the config interview (Step 0.0).
- `--preloaded` — internal, passed by `/autopilot`: Step 0.0 already ran and the config is in context.

## Step 0.0 — Init check + load project config (ALWAYS FIRST, one call)

Skip when `$ARGUMENTS` has `--preloaded` (`/autopilot` already ran this; the config is in context).

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" load; echo "rc=$?"     # add --reconfigure if passed
```
- **rc=0** → stdout **is** the config — read once, keep it in context.
- **rc=4** → `NOT_INITIALIZED` → **STOP** for this repo's PR. Tell the user to run
  **`/autopilot:init`** first (gstack, config, DESIGN.md + docs bootstrap), then
  re-run this command. PRs this chat opened in other, initialized repos still ship (Step 0).
- **rc=3** → no config (or `--reconfigure`): Read `${CLAUDE_PLUGIN_ROOT}/lib/config-interview.md` and
  run it. `/autoship` needs the tracker/review/deploy sections populated to run at all.
- **rc=2 / other** → hard loader error on stderr (commonly: `jq` missing, or a config that can't be read
  or isn't one JSON object — merge-conflict markers: fix it, or re-run with `--reconfigure`) → surface it, **STOP**.

**Shell state does not persist between Bash calls** — substitute config values literally into each
command rather than relying on variables from an earlier call (`<merge-sha>` included: once captured
in Step 4, write it into later commands verbatim).

Placeholders resolve from the config **of the repo whose PR is shipping**: `<base>` =
`.git.baseBranch`, `<KEY>` = a `<keyPrefix>-NNN` key (tracker `backlog`: any project bound to the repo; upper-case; found in a branch name
case-insensitively — `pos-42-…` carries `POS-42`), `<checks>` = `.git.protection.requiredChecks`,
`<mergeStrategy>` = `.git.mergeStrategy`, etc.
**`<subject>`** = a commit subject or PR title in `.git.commitStyle` (absent = `key-prefix`):
`key-prefix` → `<KEY>: <what + why>`; `conventional` → `type(scope): summary` (Conventional Commits
1.0, imperative, ≤72 chars, no key in the subject — it goes in a `Refs: <KEY>` commit trailer and a
`Ticket: <KEY>` line in the PR body). The PR title is the squash subject, so it follows the same rule.
**`<typecheck>`** = `"${CLAUDE_PLUGIN_ROOT}/lib/typecheck.sh"` — passes trivially when
`.commands.typecheck` is empty and is a **no-op on a working tree that already passed** (cached by
tree hash), so every gate below that re-asserts it costs nothing unless the code changed. A config
that is missing or isn't one JSON object (merge-conflict markers) fails it with rc 2, named on stderr.

**A PR in another repo** runs against its checkout `<dir>` — never `cd` there: `git -C <dir> …`;
`gh pr <cmd> <PR-url>` in place of `<PR>` (the URL carries the repo) and `-R <owner>/<repo>` for
`gh run` / `gh repo` / `gh pr list`; `gh api` paths spelled out as `repos/<owner>/<repo>/pulls/<number>/…`
(`{owner}/{repo}` expands to the **cwd's** repo); and `AUTOPILOT_REPO=<dir>` (absolute) in front of
every `${CLAUDE_PLUGIN_ROOT}/lib/*.sh` call, `<typecheck>` included.

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
  `--e2e` / `--video`; a run on video needs it only as the recorder's fallback). Missing → say the
  optional pass was skipped; never silently claim it ran.

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

## Hard gate — NEVER merge a PR unless ALL hold (for that PR, under its repo's config)

1. Auto-reviewer at `.review.passBar` AND **zero** unresolved review threads (when `.review.gate != none`).
2. `<typecheck>` exits 0.
3. Full CI rollup green — `gh pr checks <PR>` all `pass` (auto-reviewer included).
4. PR body follows `.rules.prTemplate`, no empty required sections.
5. Branch, PR title or PR body (`Ticket: <KEY>`) carries `<KEY>` (when `.tracker.keyRequired`).

If any fails and can't be auto-fixed in the loop, **STOP and report** — do not merge.

---

## Step 0 — Preflight: collect the PRs to ship

```bash
gh auth status >/dev/null 2>&1 || echo "gh not authenticated"
git rev-parse --abbrev-ref HEAD
git log --oneline "origin/<base>..HEAD" | head        # commits to ship on the current branch?
gh pr view --json number,isDraft,url 2>/dev/null || true   # /autodev usually left a draft PR
```

**The ship list.** PR refs in `$ARGUMENTS` → exactly those. Otherwise:
1. **Every PR this conversation opened, in any repo** — the URLs `gh pr create` and `/autodev`'s
   handoff printed, including PRs in sibling repos the chat worked in. GitHub doesn't record which
   chat opened a PR, so read it from the conversation. A PR that was only *mentioned* (a link the user
   pasted, someone else's PR) is not on the list.
2. **Plus the current branch** — its open PR, or, with commits ahead of `<base>` and no PR yet, the PR
   Step 1 opens. In a fresh session this is the whole list.
3. **Drop** what is already merged or closed (`gh pr view <PR-url> --json state`) — name it in the report.

For each PR, before anything merges:
- **Checkout `<dir>`** — where this chat committed it. Unsure → `git -C <any clone> worktree list`
  shows which worktree has its head branch. Checked out nowhere → leave the PR out (`no local
  checkout`); don't clone, and don't switch a branch under someone else's work.
- **Config** — the cwd repo's comes from Step 0.0. For another repo:
  `AUTOPILOT_REPO=<dir> "${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" load; echo "rc=$?"` — once per
  repo, keep it beside its PRs. Step 0.0's rc rules apply, but a STOP leaves out **that repo's** PRs,
  not the run (rc=4 → "run `/autopilot:init` in `<dir>`").
- **`<KEY>`** — if its `.tracker.keyRequired` and neither the branch nor the PR (title, `Ticket:` line)
  carries one, **STOP** and ask — one question covering every such PR. Capture the keys — Step 6
  transitions them.
- **Still wanted?** — **Read `${CLAUDE_PLUGIN_ROOT}/lib/relevance.md`** (step 4) and re-check what
  could change while the PR waited: the ticket closed or retracted, or the same change landed on
  `<base>` through another PR. Evidence → ask (one question covering every such PR) and follow the
  answer — ship it, close the PR, or hold it. Always, `--preloaded` too.

**Order.** A PR that consumes what another introduces (a shared package, an API / schema / contract
change, a migration) ships **after** it — the provider through Step 5 first, so the consumer lands on
a live provider. **A stack** — a PR whose base is another listed PR's head branch (`gh pr view
<PR-url> --json baseRefName,headRefName`) — ships bottom first: once the PR under it merges, that
PR's Step 4.1 retargets it to `<base>`, and only then does it run Step 0.5, which rebases it with
`git rebase --onto "origin/<base>" <old base head>` (a squash or rebase merge leaves the old commits
in its history, so a plain rebase would replay them). Otherwise in the order the chat opened them. Print the plan once:
`Shipping N PR(s): <owner>/<repo>#<n> (<dir>), …`.

**Then Steps 0.5–5 run once per PR, in that order**, each in its checkout under its repo's config;
Step 6 reports them all. While one PR waits in the background (CI, merge queue, deploy verify), you may
advance an independent PR from **another** repo; two PRs in one repo merge strictly in turn (the
second merge would overtake the first's deploy check). When a PR stops short:
- a hard-gate STOP (review won't converge, red CI, unresolvable conflict) drops **that PR and the PRs
  that depend on it** — the others still ship;
- a **broken deploy or real canary problem** (Step 5) halts every merge still pending — don't stack
  more merges onto a production that may be broken. Report what's left unmerged.

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
**A stacked PR whose base PR merged in this run** (Step 0) rebases with `--onto` in place of the plain
`git rebase`: `git rebase --onto "origin/<base>" <old base head>`, then `<typecheck>` and the push as
above. `<old base head>` = the `<head-sha>` its base PR's Step 4 captured, when
`git merge-base --is-ancestor <head-sha> HEAD` holds; otherwise that PR was rebased after this one
branched — `git log --oneline "origin/<base>..HEAD"` lists both PRs' commits: take the one just
below this PR's oldest own commit.

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
3. **No PR yet?** (current branch only) Populate the template into a temp file (plus the
   `Ticket: <KEY>` line under `conventional`),
   `gh pr create --base "<base>" --title "<subject>" --body-file "$tmp"`, `rm "$tmp"`.

Capture the PR number and URL (`gh pr view --json number,url`).

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

Re-confirm the hard gate, then capture the PR's branch (4.1 needs `<head>`, a stacked PR's Step 0.5
`<head-sha>`):
```bash
gh pr view <PR> --json headRefName,headRefOid --jq '"\(.headRefName) \(.headRefOid)"'   # <head> <head-sha>
```
Merge with the configured strategy — **never with `--delete-branch`**: deleting `<head>` while an open
PR is based on it makes GitHub **close** that PR instead of retargeting it. 4.1 retargets those PRs
first, then deletes the branch.
```bash
gh pr merge <PR> --<mergeStrategy>
```
**Merge queue** — when `.git.mergeQueue` is true, or the direct merge is rejected because the base
requires a merge queue: enqueue instead, `gh pr merge <PR> --auto` (the queue applies its own
strategy), then wait for it **in the background**:
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
if [ "$NOT_GREEN" = "0" ]; then gh pr merge <PR> --<mergeStrategy> --admin
else echo "ABORT: $NOT_GREEN check(s) not green — refusing --admin"; fi
```

**Capture the merge SHA** — Step 5 needs it (write it into later commands verbatim as `<merge-sha>`):
```bash
gh pr view <PR> --json mergeCommit --jq '.mergeCommit.oid // "ABORT: no merge commit SHA — did the merge land?"'
```

### 4.1 — Retarget the PRs based on its branch, then delete the branch

Only once the merge landed (a real `<merge-sha>`), in this order:
```bash
gh pr list --base "<head>" --state open --json url --jq '.[].url'   # the PRs based on <head>
gh pr edit <their-PR-url> --base "<base>"                           # each of them
gh pr list --base "<head>" --state open --json url --jq length      # must print 0
git push origin --delete "<head>"   # only with .git.deleteBranchOnMerge, and only after the 0
```
- Retarget **every** open PR based on `<head>` — this run's next PR in a stack and anyone else's — even
  when `.git.deleteBranchOnMerge` is false: a PR left on a merged branch would merge into it, not
  `<base>`. Rebase only this run's own (Step 0.5); name the others in the report — they need the same
  `git rebase --onto "origin/<base>" <head-sha>`.
- The recount isn't 0 (an edit failed, a PR was opened on `<head>` meanwhile) → retarget those and
  count again; still not 0 → **keep the branch** and report the PRs still on it. Never delete a
  branch an open PR is based on.
- Only the remote branch goes; the local one stays where it is checked out. The push saying the remote
  ref doesn't exist means the repo deletes merged branches itself — harmless.

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
# another repo's PR: AUTOPILOT_REPO=<dir> "${CLAUDE_PLUGIN_ROOT}/lib/verify-deploy.sh" <merge-sha>
```

| exit | meaning | do |
|---|---|---|
| **0** | `VERIFIED` — `build-id`: the endpoint reports `<merge-sha>`, or a later commit that contains it (`… (contains <merge-sha>)`: a builder that deploys every push built a PR merged right after — the build carries those commits too, so a canary problem may be theirs); `github-run`: the deploy run(s) for `<merge-sha>` went green | continue to the canary |
| **1** | `BROKEN` — a deploy run failed, or the build-id endpoint was unreachable the whole window | **hard STOP**: skip 5.5 / 5.6 / 6, surface it, offer the **revert recipe** |
| **10** | `UNVERIFIED` — old build still answering at the deadline, no push run observed, mode `none`, or the live build contains `<merge-sha>` but also reverts it | **unverified** (below) |
| **12** | `COMMIT_UNKNOWN` — the endpoint answers but its commit reads `unknown`/empty (the build arg never arrived — **not** a failed deploy) | if it printed a `restartedAt` **after** the merge time, count it as deployed and say the evidence was the restart, not the commit; else **unverified** |
| **2** | config/usage error, named on stderr (no config, one it can't read or that isn't one JSON object, a `timeoutSeconds` that isn't a whole number of ASCII digits or is over 86400 (a day), `build-id` without `buildIdUrl`) | fix the config, re-run |

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
- **UI change** → invoke **`.deploy.canarySkill`** against the deploy URL (arg — cwd repo's PR only —
  else `.deploy.urls.client`, else the first `.deploy.urls` entry) for a quick page-load smoke of the
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

## Step 5.6 — Optional scenario browser e2e (`--e2e`, `--video`)

Only with `--e2e` or `--video` (else skip silently). Otherwise **Read `${CLAUDE_PLUGIN_ROOT}/lib/e2e.md`**
and follow its **deployed** mode against the deploy URL: 2–4 scenarios from the diff + `<KEY>` + PR
body, recorded with `--video` or `.qa.video.enabled` (and attached to a backlog issue), **report-only**
(merged code — fixes are follow-up PRs). A scenario failing **because of this ship** → **blocks Step
6** + offer revert or fix-forward; pre-existing breakage → include, don't block. Write the run into
the final report.

## Step 6 — Report + move the ticket to the ship status

Print the report — one block per PR, in ship order:
```
/autoship complete — <N> PR(s) shipped, <M> not.
  PR:        <owner>/<repo>#<n> — <title>
  Review:    <gate> <iters>, <passBar>, <N> resolved   (or: gate=none)
  CI:        green (<checks>)
  Merge:     <mergeStrategy> <SHA> (direct | --admin)[, retargeted to <base>: #<n>…][, branch kept: #<n> still on it]
  Deploy:    <env> — <verified <SHA> via <mode>[, live <later sha> contains it] | UNVERIFIED: <why>>, canary <ok | issues>   (or: deploy=none)
  QA:        <--qa not passed | ok | N findings (blocking: yes/no)>
  E2E:       <--e2e not passed | N scenarios ok | M failed (blocking: yes/no)>
  Video:     <path(s) | gif in PR>[ · attached to <KEY>: N] | n/a: why
  Follow-ups: <N proposed in Step 7 | none>

  Not shipped: <owner>/<repo>#<n> — <why: stopped at Step X | depends on #m | left out: no local
               checkout / repo not initialized | already merged / closed | held / closed at the
               relevance re-check: <evidence>>
```
Then **transition each ticket `<KEY>` to `.tracker.shipStatus`** — once per distinct key, via the
`.tracker` of the repo its PRs belong to, and only when **every** PR in this run that carries it
passed the guards below (a feature split across repos isn't shipped until all its PRs are). Running
`/autoship` is the explicit go-ahead, so this step **acts** (doesn't just remind). Skip entirely when
`.tracker.type == none`.
**`backlog`** has no workflow transitions. A PR with no `<KEY>` in its branch, title or body may still
have an issue: the `Tracker issue:` key in this chat, else `<mcp>__list_issues` with `branch` = the PR's
head branch (the tracker links Constructor workspaces to issues). Then `<mcp>__get_issue`; already
`.tracker.shipStatus` → skip (`already <shipStatus>` — its sync marks merged work done, so this is
common) but still comment; else `<mcp>__update_issue` with `status: <shipStatus>`. Either way
`<mcp>__add_comment` naming the merged PR(s) and the deploy verdict. Print the status reached.

Any other tracker — via the configured tracker MCP (`.tracker.mcp`, e.g. `mcp__jira-server__*`):
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
didn't flag a real problem AND (if `--qa`) no blocking regression AND (if `--e2e`/`--video`) no
scenario failing because of this ship. Any PR carrying `<KEY>` stopped short → **DO NOT transition**
it; report the blocker. Tracker MCP unavailable / key not tracked → **skip** with a one-line note, don't fail the run.

## Step 7 — Follow-ups

Skip when `--preloaded` (`/autopilot` proposes them once, after its combined report). Otherwise
**Read `${CLAUDE_PLUGIN_ROOT}/lib/follow-ups.md`** and propose follow-up tasks from this ship — the
report-only QA / e2e findings and canary notes that didn't block, a deploy left UNVERIFIED, review
threads resolved as "later", PRs that weren't shipped and why. Runs after the ticket move, so it never
holds up the ship; the operator's picks are filed, the rest is printed.

---

### Notes
- Ships every PR the chat opened, across repos (Step 0) — name PR refs to ship fewer. `/autopilot`
  passes the PRs its own `/autodev` phase opened, so drafts still awaiting your verification stay put.
- Pairs with `/autodev` (plan→build→test→draft-PR→verify-gate). For the no-verification single-shot
  variant see `/autopilot` (autodev + autoship back-to-back, staging QA ON by default).
- Stacked PRs (each based on the previous one's branch) ship bottom first. A merged PR's branch is
  deleted only after the open PRs based on it are retargeted to `<base>` (Step 4.1) — `gh pr merge
  --delete-branch` would delete it first, and GitHub then closes them. With `.git.deleteBranchOnMerge`,
  a two-PR stack ends with the second PR open and based on `<base>`, rebased with
  `git rebase --onto` (Step 0.5), and shipped in turn.
- Intentionally uses repo-aware `--admin`/`update-branch` (gated on config) so it never stalls on
  strict protection. The e2e videos (Step 5.6, backlog), the ticket move (Step 6) and the follow-ups
  the operator picks (Step 7) are the only places `/autoship` writes to the tracker.
- Project-independent: all facts from `.claude/autopilot.config.json`. To share the commands
  themselves across repos, install the `autopilot` plugin: `claude plugin marketplace add HireAll-ai/autopilot-skills`.
