# Follow-up tasks (shared by /autodev, /autoship, /autopilot)

The last thing a run does: turn what it deliberately left undone into tasks the operator can file with
one pick, so it doesn't evaporate with the chat — **few and strong**, because every issue filed is one
more for a person to read, and an agent to build, review and ship. Skip entirely when
`.tracker.followUps` is `off`. Inside `/autopilot` this runs **once**, after the combined report — not
after each phase.

**Follow-ups — only what matters.** The same four rules in `lib/follow-ups.md`, `/autodev` and `/autoship`:
- **The bar.** A follow-up issue is one of: a bug that breaks or blocks a user; a regression or
  failure on the deployed server; scope deliberately cut from this task, with the decision recorded.
  Medium/low findings, pre-existing breakage that blocks no one, polish, extra tests and CI, refactors
  and hardening against unlikely inputs don't become issues: the run's report lists them under
  **Not filed**, and the worthwhile ones go into the project's Intake (`mcp__backlog__add_requirement`,
  kind `bug` or `idea`) when the backlog tools resolve.
- **The cap.** At most **3** follow-up issues per run (`/autopilot` proposes once, for both phases).
  The strongest stay; the rest go to **Not filed**.
- **Same mistake, same PR.** When a bug you fix has siblings — the same pattern elsewhere in the
  repo — fix them in this PR while it stays XS–S. Never a follow-up per place.
- **Dedup by meaning.** Before proposing, search the tracker by the key terms and the files the
  follow-up touches, not only its title (`list_issues` with `query`), in every status. An open or
  done issue that covers it drops it; **Not filed** names that issue.

## 1. Collect candidates — from this run only

What this run saw and left undone — step 2 decides which of them may become an issue:
- scope you cut or deferred ("out of scope", "later", "separate PR"), and decisions you recorded that
  need a follow-through;
- review findings below the pass bar or left unfixed, and report-only QA / e2e findings and canary
  notes on merged code (`/autoship` 5.2 / 5.5 / 5.6);
- gates that did **not** run because something is missing (a skill, a preview env, a dev sign-in route);
- test backdoors / fast paths you offered instead of adding (autodev Rules), and **Not verified
  locally** items that need real work to verify, not just a look after deploy;
- `TODO` / `FIXME` lines this diff added: `git diff <base>...HEAD | grep -E '^\+.*(TODO|FIXME)'`.

Not candidates at all: anything already done, vague wishes ("improve performance"), restatements of
the PR, items the operator already said no to, **what this run broke** (fix it in this PR before it
ships — that's not follow-up work), and **siblings of a bug this run fixed**: the same mistake in
another place is fixed in the same PR (`/autodev` Rules). Only when that would have pushed the PR past
S do the places left become **one** candidate that names them all — never one per place — and it still
has to pass the bar.

## 2. The bar — an issue, or Not filed

Each candidate passes only as one of:
- **a bug that breaks or blocks a user** — a flow that errors, loses data, or can't be finished; a
  pre-existing one too, when this run hit it. Not: a wrong label, a misaligned row, a slow page that
  still works;
- **a regression or failure on the deployed server** — a canary problem, a QA / e2e failure caused by
  this ship, a broken deploy: its fix-forward, unless the operator reverts instead;
- **scope deliberately cut from this task, with the decision recorded** — in the handoff's
  `Decisions`, the PR body or a comment on the issue. A thought you didn't get to isn't cut scope.

Everything else is **Not filed** (step 9): medium/low QA, e2e and review findings; pre-existing
breakage that blocks no one; polish; extra tests and CI; refactors; hardening against unlikely inputs
(odd encodings, values nobody writes); gates that didn't run; test backdoors; `TODO`s that don't mark
cut scope. A run whose QA found five medium/low notes proposes **no** issue — the five are listed as
Not filed, the worthwhile ones put into Intake.

## 3. Where they go

- **The backlog.** When the `mcp__backlog__*` tools resolve, `mcp__backlog__list_projects` with
  `repoPath` = the repo's main checkout (`git worktree list --porcelain | sed -n '1s/^worktree //p'`)
  gives this repo's projects — often several (a monorepo's sales / marketing / admin areas), each with
  a `scope`. That holds even while `.tracker` still names the tracker the repo is moving off; say so
  and suggest `/autopilot:init` to switch it.
- **Else `.tracker`** (`jira` / `github` via its MCP or CLI), **else** nowhere: the drafts
  are printed.

## 4. Drop duplicates — by meaning: the tracker, the base branch, open PRs

A candidate is a duplicate when the work already exists **anywhere**, not just as an open ticket under
the same title: other chats ship in parallel, the same mistake gets filed once per place it shows up,
and work can land on `<base>` without a ticket. Check all three, for each candidate that passed the
bar, right before proposing:

1. **The tracker, every status — by meaning, not by title.** Search by the candidate's key terms (the
   nouns of the problem, synonyms, in the language the tracker's titles are written in — often not
   English) **and** by the files, functions or config keys it touches (`verify-deploy.sh`,
   `timeoutSeconds`), not only its title: one query per term, **without a status filter** (backlog:
   `mcp__backlog__list_issues` with `project` + `query` — it matches descriptions and comments too;
   other trackers: their search, including closed). Read the hits that name the same file or the same
   problem: one that covers the candidate — the same mistake in another place or other words — is its
   duplicate. Also read the run's own issue (`get_issue` → `followUps`) so a re-run doesn't refile
   what it filed last time.
   - open (backlog / todo / in progress / in review) → drop, `duplicate of <KEY> (open)`;
   - done → drop, `duplicate of <KEY> (done)` — unless this run shows it broken again: then it's a
     regression, keep it and name `<KEY>` in the why;
   - canceled → the operator decided against it: drop, `declined: <KEY>` — propose it again only with
     new evidence from this run, and name `<KEY>` in the why.
2. **The base branch.** `git fetch origin "<base>" -q`, then what landed since this branch forked —
   `git log --oneline "$(git merge-base HEAD origin/<base>)..origin/<base>"` — and
   `git grep -n -i '<identifier>' origin/<base> -- <paths>` for the candidate's concrete hooks (a
   route, an MCP tool, a column, a component). Fully there → drop, `already on <base>: <sha> (#n)`.
   Partly there → keep it, but narrow the brief to what's missing and name the commit / PR it builds on.
3. **Open PRs** — `gh pr list --state open --json number,title,headRefName` (plus `-R <owner>/<repo>`
   for each other repo a candidate routes to): one already doing it → drop, `in flight: #n`.

## 5. The cap — at most 3 per run

More than 3 left → keep the 3 strongest: a regression or failure on the deployed server first, then a
bug that breaks or blocks a user (more users, or blocked harder, first), then cut scope. The rest go to
**Not filed** as `over the cap`. `/autopilot` proposes once for both phases, so the cap is per run,
not per phase.

No candidates left → a single `Follow-ups: none` line in the report, plus the **Not filed** list
(step 9), no question.

## 6. Draft each one

- **Title** — imperative, ≤70 chars.
- **Brief** — self-contained, because it becomes the agent's prompt when the task is started later
  (for backlog, as the first message of a new Constructor workspace): the context with file paths,
  what to do, **done when**, and what not to touch. Name the PR / `<KEY>` it came from. A bug: every
  place it shows up, so its fix covers them all.
- **Project** — route by scope: the backlog project whose `scope` covers the files / area the task
  touches (`apps/backend/src/sales` → the sales project). Unclear between two → the closer one, with
  the other named in the why so the operator can redirect it. One project → it. Work that belongs to
  another repo goes to that repo's projects (`list_projects` with that repo's root). Without backlog
  projects: `.tracker.keyPrefix`.
- **Priority** — only when it's clear (a found regression is high); else none.
- **Size** (backlog) — XS / S / M / L / XL, honestly: it picks how the task starts in Constructor —
  XS–S with `/autopilot:autopilot` (ships on its own), M+ with `/autopilot:autodev` (stops for a human
  to verify). Unsure → the larger one.

## 7. Propose — the operator picks

**Backlog in Constructor's agent chat → cards, not a question.** When the candidates go to backlog
projects, the tracker MCP has `propose_issues` (`mcp__backlog__propose_issues` resolves) and the run is an
agent in Constructor's chat (its instructions say you work inside Constructor), call it **once** with
every candidate: `followUpOf` = the issue this run was started for (`<KEY>`, as in step 8), and per
candidate `project`, `title`, `description` = the brief, `size`, `priority` (when clear) and `why` = the
one-line why. Call it from the main conversation, not a subagent. It files nothing: the chat shows each
as a card with **Backlog** / **Todo** buttons (and Add all), and the operator files what they want with a
click — so **don't ask** which to file, and **skip step 8** (filing them yourself would duplicate the
operator's clicks). Print one line instead: `Follow-ups: proposed N as cards (<titles>)`, plus the
**Not filed** list (step 9). Candidates for a repo without backlog projects still go in a printed block.
If the call fails, fall back to the table and the question below.

**Otherwise** print a numbered table (`# · title · project · size · priority · why`) and, under it, the
**Not filed** list (step 9), so the operator can overrule a false match or a call on the bar. Then ask
with `AskUserQuestion` (`multiSelect: true`), one question — option label
`<title> → <PROJECT> · <size>`, description = the one-line why. No `AskUserQuestion` (headless /
non-interactive run) → print the drafts as a copy-pasteable block and **file nothing**.

**Never file a task the operator didn't pick** — a run that opens tickets on its own fills the board
with noise and overrides teams that reserve ticket creation for a human.

## 8. File the picked ones

(Not after `propose_issues` — the operator files those from the cards.)

If the operator answered after the base or the tracker could have moved (another turn, a long wait),
re-run step 4 on the picked ones first — a parallel chat may have filed or shipped one meanwhile;
drop or narrow it and say so.

- Backlog → `mcp__backlog__create_issue` with `project` (as routed, or as the operator redirected it),
  `title`, `description` = the brief, `priority`, `size`, and `followUpOf` = the issue this run was
  started for (`<KEY>`, the `Tracker issue:` line, or `list_issues` with `branch` = this branch) — the
  tracker links the two both ways.
- `jira` / `github` → that tracker's create tool via `.tracker.mcp` (`github` without an MCP:
  `gh issue create --title … --body-file …`), with a "Follow-up of `<KEY>`" line at the top of the body.
- Nowhere to file, or the tracker isn't reachable → print the picked briefs as a copy-pasteable block.

Report line: `Follow-ups: filed SALES-12, MKT-4 · not picked 1` (for backlog issues, add each URL — it
opens the issue, and **Start** there opens a new Constructor workspace), plus the **Not filed** list.

## 9. Not filed — the report, and Intake

Everything steps 2, 4 and 5 set aside goes into the run's report under **Not filed**, one line each,
with why:
```
Not filed:
  - <what, file:line> — below the bar: <medium QA | polish | tests | hardening | …>[ → Intake <kind>]
  - <what> — over the cap[ → Intake <kind>]
  - <what> — duplicate of <KEY> (open | done) · declined: <KEY> · already on <base>: <sha> (#n) · in flight: #n
```

**Intake.** When `mcp__backlog__add_requirement` resolves and the repo has backlog projects, put the
worthwhile ones — real, specific, worth doing some day; not nits, not duplicates — into the Intake of
the project whose scope covers them (step 3), one entry each: kind `bug` for something broken (a
medium/low bug, pre-existing breakage), `idea` for the rest (polish, tests, CI, refactors, hardening,
a gate that didn't run); `text` = what and where (`file:line`), why it matters, and where it came from
(`<KEY>`, PR #n). First `mcp__backlog__list_requirements` with `project`: an open entry that already
says it → skip it, and an issue that covers it (step 4) → no entry. Intake isn't the backlog — its
entries wait for the operator to fold into an issue or drop — so the run adds them without asking and
marks them `→ Intake <kind>` in the list. Without the tool, the list is all there is.
