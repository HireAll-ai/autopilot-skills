# autopilot (plugin)

Project-independent `/init`, `/autodev`, `/autoship`, `/autopilot`. The command bodies contain **no**
project-specific literals — they read `.claude/autopilot.config.json` (per-repo, committed) at Step 0.0.
Bundled scripts are referenced via `${CLAUDE_PLUGIN_ROOT}`, so the plugin works from wherever Claude
Code installs it.

## Install

```bash
claude plugin marketplace add HireAll-ai/autopilot-skills
claude plugin install autopilot@autopilot-skills
```

## First run (per repo) — `/autopilot:init` (required)

Every repo must be initialized once before the other commands run (they check the
`.claude/autopilot.init.json` marker and stop otherwise). `/autopilot:init`:

1. verifies **gstack** is installed (installs it if missing) — the QA steps (review/canary when
   configured) and the bootstraps delegate to gstack skills (`/qa`, `/design-consultation`, `/document-generate`, …);
2. ensures `.claude/autopilot.config.json` (same detect-and-confirm interview as below);
3. makes the **backlog** tracker (below) the repo's tracker — binds its projects (several per
   repo: a monorepo's sales / marketing / admin areas, each with a scope) and switches the config off
   Jira / GitHub;
4. bootstraps the **design system** — gstack `/design-consultation` → `DESIGN.md` (UI products);
5. bootstraps **baseline documentation** — gstack `/document-generate` (Diataxis baseline);
6. writes the `.claude/autopilot.init.json` marker and commits.

Idempotent; flags: `--force`, `--skip-backlog`, `--skip-design`, `--skip-docs` (steps 3, 4, 5 —
`--force` with all three redoes only the config, e.g. one left with merge-conflict markers).

## Backlog tracker + follow-ups

The [ai-backlog](https://github.com/gitEventyr/ai-backlog) tracker is the default tracker
(`tracker.type: "backlog"`; Jira / GitHub still work), hosted or local. It serves its own MCP
server — register it once per machine, a hosted tracker with its token:

```bash
claude mcp add --transport http --scope user backlog https://<tracker>/mcp \
  --header "Authorization: Bearer <token>"
codex mcp add backlog --url https://<tracker>/mcp --bearer-token-env-var BACKLOG_TOKEN   # Codex
# a local tracker (corepack pnpm start in ai-backlog): http://127.0.0.1:4400/mcp, no token
```

The config autodetect finds the tracker through Claude Code's registration: it asks the `backlog`
server's URL, with its headers, which projects are bound to the repo — local scope, then the repo's
`.mcp.json` only once you approved it on this machine (your settings, `.claude/settings.local.json`;
never the repo's committed `settings.json`), then user scope. In its URL and headers `${VAR}` expands
for `BACKLOG_*` and `AUTOPILOT_*` names only. `AUTOPILOT_BACKLOG_URL` overrides the URL and
`AUTOPILOT_BACKLOG_TOKEN` the token — what a Codex session needs, since detect doesn't read Codex's
config; with none of these, it tries `http://127.0.0.1:4400`.

- **Projects, several per repo.** A backlog project points at one repo and says which part of it it
  covers (`scope`); a monorepo usually has several (plurex: sales, marketing, admin).
  `/autopilot:init` binds them and switches the repo's config to the backlog; keys of every bound
  project are valid, `keyPrefix` is the default one.
- **Issues start the right command.** **Start** on an issue opens a Constructor workspace whose prompt
  is `/autopilot:autopilot` (size XS–S: ships on its own) or `/autopilot:autodev` (M and up: stops at a
  draft PR for you to verify), followed by the project, the task and its brief. The tracker estimates
  the size from the brief; anyone can override it. A repo `/autopilot:init` hasn't set up gets a plain
  brief instead.
- `/autodev` takes `<KEY>` from the `Tracker issue: <KEY>` line and comments the draft PR on the issue;
  `/autoship` Step 6 sets it to `done` (found by key, or by the PR branch through the tracker's
  workspace links).
- E2e videos land on the issue: every video an `--e2e` run records (`--video`, or `qa.video.enabled`)
  is attached with the tracker's `attach_video` and plays on the issue's page (below).

**Follow-ups** (`tracker.followUps`, default `ask`): at the end of `/autodev`, `/autoship` and — once —
`/autopilot`, the run drafts follow-up tasks from what it deliberately left undone, routes each to the
backlog project whose scope covers it, sizes it (which picks its command on Start), drops duplicates
(tickets in any status, found by key terms and the files they touch, not only by title; work already on
the base branch; open PRs), and asks which to file — in Constructor's agent chat it proposes them with
the tracker's `propose_issues` instead, which shows each as a card with Backlog / Todo buttons that file
it with a click. Only what matters becomes an issue:
- **the bar** — a bug that breaks or blocks a user, a regression or failure on the deployed server, or
  scope deliberately cut with the decision recorded;
- **the cap** — at most 3 per run (`/autopilot` proposes once, for both phases), the strongest first;
- **same mistake, same PR** — siblings of a bug the run fixed are fixed in that PR, never filed one per
  place.

The rest — medium/low findings, polish, extra tests and CI, refactors, hardening against unlikely
inputs, what's over the cap or a duplicate — is listed in the report under **Not filed**; the worthwhile
ones go into the project's Intake (`add_requirement`, kind `bug` or `idea`) without a question, since
the inbox is where loose notes wait for you. No issue is filed without a pick. Procedure:
[`lib/follow-ups.md`](lib/follow-ups.md).

## Relevance check — first, every run

A task can go stale between filing and starting: the work lands on the base branch without the
ticket, a parallel chat takes it, a comment retracts it, or the code it describes is gone. So
`/autodev` (and with it `/autopilot`, `--preloaded` included) starts by checking — the issue's status,
later comments and similar issues in any status, what landed on the base since it was filed, open PRs,
and whether the files, routes and bug the brief names are still there. Concrete evidence → it asks
(`AskUserQuestion`) and waits: continue, narrow to what's left, close the issue as done / canceled, or
stop. No evidence → no question, one `Relevance:` line in the handoff. A task's age or a terse brief
alone is not a reason to ask. `/autoship` re-checks before merging what can change while a PR waits —
the ticket closed or retracted, the same change merged through another PR. Headless runs that can't
ask stop instead of building. Procedure: [`lib/relevance.md`](lib/relevance.md).

## Config — detect + confirm

On the first `/autodev` (or `/autopilot`) in a repo with no config, Step 0.0 autodetects and asks you
to confirm/fill the gaps, then writes + `git add`s `.claude/autopilot.config.json`. Autodetected:
package-manager commands (lockfile + `package.json` scripts), base branch + protection
(`gh api …/branches/<base>/protection`), ticket prefix and commit style (commit history), a
health/deploy URL, and the backlog tracker with the projects bound to the repo (through the `backlog`
MCP server's registration — when it can't list them, the draft's `_note` says why). You confirm the
rest: tracker type + MCP + ship status, review gate, deploy URLs, whether to enable video. Re-run any time with `--reconfigure`.

The commands load it with **one** call at Step 0.0 — `autopilot-config.sh load` checks the init marker
(exit 4 if missing) and prints the config (exit 0) or an autodetected draft (exit 3) to stdout, so the
agent reads the config once into context instead of re-querying it per value. A config it can't read
or that isn't one JSON object (merge-conflict markers) stops it with exit 2 and the cause on stderr —
the broken text never reaches the agent; `--reconfigure` still works on one that isn't JSON, starting
the interview from the draft. One it can't read stays exit 2 with `--reconfigure` too, and stderr says
to fix its permissions: the interview couldn't rewrite it either. The interview itself
lives in [`lib/config-interview.md`](lib/config-interview.md) and is only read when needed.

Preview / inspect via the loader (resolve the plugin dir with `claude plugin root autopilot`):

```bash
PLUGIN="$(claude plugin root autopilot)"     # e.g. ~/.claude/plugins/.../autopilot
"$PLUGIN/lib/autopilot-config.sh" detect      # print an autodetected draft
"$PLUGIN/lib/autopilot-config.sh" backlog     # probe the backlog tracker: up <keys> | refused <url> <code> | down <url> <code> | unusable
"$PLUGIN/lib/autopilot-config.sh" validate     # check the written config
"$PLUGIN/lib/autopilot-config.sh" timeout      # .deploy.verify.timeoutSeconds in seconds, checked (600 if unset)
"$PLUGIN/lib/autopilot-config.sh" get '.git.baseBranch'
```

## Config reference

Full contract: [`schema/autopilot.config.schema.json`](schema/autopilot.config.schema.json). Sections:
`tracker` (issue tracker + ship status), `git` (base branch, branch pattern, commit style, merge
strategy, protection), `commands` (install/typecheck/test/build/dev — empty string = "skip this
step"), `review` (auto-reviewer gate + pass bar + local reviewers), `deploy` (trigger, healthcheck, env URLs, canary skill), `qa` (browser
skills + `preview` + `video`), `rules` (which repo docs to obey + plan/spec dirs + PR template).

A consuming repo's config commonly starts with:

```json
{
  "$comment": "Consumed by the autopilot plugin — claude plugin marketplace add HireAll-ai/autopilot-skills",
  "version": 1,
  "tracker": { "type": "jira", "keyPrefix": "PROJ", "keyRequired": true, "shipStatus": "In Review" },
  "...": "see the schema"
}
```

## Commit style, branch names, tickets

The repo's conventions, not the plugin's — set once in config, applied to every commit and PR title
`/autodev`, `/autoship` (and so `/autopilot`) write:

- **`git.commitStyle`** — `key-prefix` (default): `POS-42: add the role filter`. `conventional`:
  Conventional Commits 1.0, `feat(roles): add the role filter` (imperative, ≤72 chars, no key in the
  subject); the key moves to a `Ticket: POS-42` line in the PR body and a `Refs: POS-42` commit
  trailer. The PR title is the squash subject, so it follows the same style.
- **`git.branchPattern`** — `{key}`, `{key_lower}`, `{slug}`: `{key_lower}-{slug}` →
  `pos-42-role-filter`. The key is found in a branch name case-insensitively.
- **`tracker.autoCreateIssue`** — default `false`: when `tracker.keyRequired` and there's no key,
  `/autodev` **asks** for one. `true` lets it open the issue itself via `tracker.mcp`.

```json
"tracker": { "type": "backlog", "mcp": "mcp__backlog", "keyPrefix": "POS", "keyRequired": true, "autoCreateIssue": false },
"git": { "branchPattern": "{key_lower}-{slug}", "commitStyle": "conventional", "...": "…" }
```

## Multi-repo chats (`/autoship`)

One chat often spans repos — an API change here, its client in a sibling repo. `/autoship` ships
**every PR the chat opened**, not just the current repo's: it reads the PR URLs from the conversation
(plus the current branch's PR), loads each repo's own config from that repo's checkout, and runs
review → merge → deploy check per PR — a provider before its consumer, otherwise in the order they
were opened. A PR that stops short holds back the PRs that depend on it; a broken deploy halts every
merge still pending. A ticket shared by several PRs moves only once all of them shipped.

- `/autoship #277 owner/other#12` ships only the named PRs. `/autopilot` names the PRs its own
  `/autodev` phase opened, so drafts still awaiting verification aren't swept in.
- Each repo needs its own `/autopilot:init`; an uninitialized one is left out and reported.
- A PR whose branch isn't checked out anywhere locally is left out — `/autoship` never clones.

## Rebasing (`/autoship`, `/autodev`)

**Base not strict → being behind is fine; every push restarts CI and the auto-reviewer; rebase only
on a conflict or a moved contract.** With `git.protection.strict` false, `/autoship` merges a branch
that is behind but mergeable as it is — no rebase, no force-push, no `gh pr update-branch`. It
rebases when GitHub reports the PR `CONFLICTING` / `DIRTY`, when shared surface the diff depends on
(`packages/*`, migrations, an API contract, `package.json` / lockfile) moved on the base, for a
stacked PR whose base PR just merged (`--onto`), and when the PR doesn't exist yet. A strict base
can't merge a behind branch, so there it rebases whenever the base moved. A review score stuck below
the pass bar gets one re-review of the same head, not a rebase. `/autodev` follows the same rule
before its draft PR, so the CI run it pre-warms isn't thrown away. The why and the pitfalls:
[`docs/rebasing.md`](../docs/rebasing.md).

## Runtime helpers

| script | used by | what it saves |
|---|---|---|
| `lib/typecheck.sh` | every `<typecheck>` gate in `/autodev` + `/autoship` | runs `.commands.typecheck` at most once per working tree (cache keyed by tree hash under the per-worktree git dir), so re-asserting the gate after a no-op rebase/push is free. A config that is missing or isn't one JSON object fails it with rc 2 — `autopilot-config.sh get` refuses it rather than read every key as its default |
| `lib/verify-deploy.sh <merge-sha>` | `/autoship` Step 5.1 | one background call per `.deploy.verify.mode`; `build-id` also counts a later commit that contains the merge and doesn't revert it (`git merge-base --is-ancestor`, after a fetch of the base branch when git doesn't know the commit — a builder that deploys every push may build the PR merged right after); `github-run` filters to `.deploy.verify.workflow` (else every push run for the SHA must go green). Exit 0 verified / 1 broken (a deploy run failed, or the build-id endpoint was down on every poll, 3 or more) / 10 unverified (an endpoint down on the only poll or two of a short window, too) / 12 commit unknown / 2 usage or config error, named on stderr (no config, one it can't read or that isn't one JSON object, a `timeoutSeconds` that isn't a whole number of seconds from 0 to 86400 (a day), too — `autopilot-config.sh timeout` checks it, the check `validate` runs as well, so a config that validates isn't refused after the merge). `timeoutSeconds` 0 looks once in either mode and doesn't wait |

`autopilot-config.sh`, `typecheck.sh` and `verify-deploy.sh` all take `AUTOPILOT_REPO=<dir>` to act
on another checkout than the cwd — how `/autoship` handles a PR in a sibling repo without `cd`.

Before changing `/autoship`'s merge steps (stack order, Steps 0.5, 4, 4.1), run `autopilot/test/stacked-merge.sh`: it ships a
PR stack against a local bare repo and a `gh` stub, and exits 1 if a PR got closed, calls ran out of order or a branch was deleted under an open PR.
It also moves `main` under a PR and runs Step 0.5's rebase rule: behind but mergeable on a non-strict base, the PR must merge with its
head unchanged (no rebase, no force-push); conflicting, on a strict base, or with `package.json` moved, it must be rebased first.
Before changing `autopilot-config.sh` or `typecheck.sh`, run `autopilot/test/config.sh` — under `/bin/bash` too on a Mac (3.2,
the bash a stock Mac runs them with): in throwaway repos and offline (`gh`, `curl`, `npx` stubbed), it checks `load`'s exit
codes, `get`, `validate` (with its `timeoutSeconds` check) and `timeout`, `AUTOPILOT_REPO`, the typecheck cache and `detect`'s backlog probe (a `curl` answering from canned
files: where the MCP server comes from, `${BACKLOG_*}`, the token, up / refused / down / unusable), and exits 1 if any of them broke.
Before changing `verify-deploy.sh`, run `autopilot/test/verify-deploy.sh` the same way: with `curl`, `gh` and `sleep` stubbed
it runs every mode against a throwaway clone — the merge, a later commit that contains it (fetched too), a revert, the
deadline, `timeoutSeconds` 0, an unknown commit, an endpoint down on one poll or on all, deploy runs green or failed, usage errors — and checks each exit code.

Long waits (CI watch, merge queue, deploy verify) are run with `run_in_background` — the Bash tool caps
foreground calls at 10 minutes. `/autodev`'s local reviewers and QA run as **parallel report-only
subagents**; the main agent applies the fixes. `/autopilot` loads the config once and passes
`--preloaded` to both phases.

**Tracker MCP permissions.** `allowed-tools` can't follow the configured tracker, so only the Jira
and `backlog` server tools are pre-approved. For another tracker (e.g. GitHub through its MCP
server), add that server to the consuming repo's `.claude/settings.json` → `permissions.allow` (e.g.
`"mcp__github"`) so `/autoship` Step 6 and the follow-up filing don't stop on a permission prompt.

## Video recording (opt-in)

The `--e2e` procedure (scenarios, recorder exit codes, fix-loop vs report-only, video surfacing) lives in
[`lib/e2e.md`](lib/e2e.md) and is only read when `--e2e` or `--video` is passed. When `qa.video.enabled`
is true, or the run has **`--video`** (`/autodev`, `/autoship`, `/autopilot`; it implies `--e2e` and
records that one run whatever the config says), the `--e2e` scenario walk is recorded via
`lib/record-e2e.mjs` (standalone Playwright — independent of any project browser tooling):

```bash
node "$(claude plugin root autopilot)/lib/record-e2e.mjs" scenario.json \
  --out-dir .context/video --format mp4 --gif --base-url http://localhost:5173 --max-seconds 90
```

- **Scenario** = JSON with `steps` (`goto`/`fill`/`click`/`press`/`waitFor`/`expect`/`screenshot`/`wait`).
- **Output**: a `.webm` always; `.mp4`/`.gif` when **ffmpeg** is installed (else the `.webm` is kept —
  GitHub and Chromium play webm). `--gif` adds a gif alongside the primary format.
- **Playwright** is a soft dep, looked up in the project (the cwd), then in `~/.autopilot/playwright`
  (`AUTOPILOT_PLAYWRIGHT_DIR` picks another directory), then next to the recorder. Install it once in
  the second — it is outside the plugin cache, so plugin updates keep it:

  ```bash
  npm i --prefix ~/.autopilot/playwright playwright \
    && node ~/.autopilot/playwright/node_modules/playwright/cli.js install chromium
  ```

  Chromium goes to Playwright's shared browser cache (`PLAYWRIGHT_BROWSERS_PATH` when set, else
  `~/Library/Caches/ms-playwright` on a Mac, `~/.cache/ms-playwright` on Linux), where a build that's
  already there is reused. Not found, or none found can start Chromium and record → the recorder exits
  **2** and prints one install command (or, when the system lacks Chromium's libraries, the
  `install-deps` to run as root): with `--video` the agent runs it and re-runs once, otherwise (or when
  that fails) the e2e step falls back to the non-video browser pass. Exit **3** = scenario/usage error
  (fix + re-run, no fallback).
- **Backlog**: with `tracker.type: "backlog"` and a `<KEY>`, each video (mp4, else webm) is attached to
  the issue — `attach_video` hands out a one-time upload URL, `curl -fsS -T <file> '<uploadUrl>'` sends
  it — whatever `qa.video.surface` says. A brief with the tracker's `Video:` line counts as `--video`
  until the tracker passes the flag itself.
- **Surfacing** (`qa.video.surface`): `context` → artifact under `.context/` referenced in the handoff
  (renders in the Constructor chat; gif previews inline); `pr-gif` → a committed gif referenced by raw
  URL in the PR body (GitHub can't embed API-uploaded video); `both`; `none`.

## Verification handoff (`/autodev`)

`/autodev` stops for a human to verify, so it hands over something clickable rather than a
paragraph: a **live preview link** to the running dev server (URL read from the server's own
output, `curl`-checked before it's printed, the server left up), routed through
`qa.preview.authPath` (e.g. `/dev-login`) so the link lands past the login wall and on the changed
surface — plus a **test plan** at `.context/testplan-<KEY>.md`: 5–10 `do X → expect Y` checks, what
could **not** be verified locally, and where to look when it's wrong. The server runs in a process
group of its own and is stopped by that group (`kill -- -<pid>`), never by `pkill` / `killall` on a
name: on a machine where several agents run as one user, that stops their servers too.

When reaching the state under test takes more than ~3 manual steps, it also hands over a
**fast-path link** that lands directly in that state — an existing deep link, or a scratch seed
script under `.context/` that creates the fixture and prints its URL. It will **not** add
prefill/backdoor code to the product to make testing easier; that gets offered, not done.

```json
"qa": { "preview": { "authPath": "/dev-login", "url": "http://localhost:$CONDUCTOR_PORT" } }
```

Both keys are optional: `url` is only needed when the bound URL isn't in the dev server's output
(sandbox-assigned port), `authPath` only when the app has a login wall.

## Requirements

`git`, `gh`, `jq` required. `ffmpeg` optional (mp4/gif). `playwright` optional (video; once in `~/.autopilot/playwright`). `node` for the recorder.
