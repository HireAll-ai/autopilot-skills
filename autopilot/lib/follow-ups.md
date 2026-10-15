# Follow-up tasks (shared by /autodev, /autoship, /autopilot)

The last thing a run does: turn what it deliberately left undone into tasks the operator can file with
one pick, so it doesn't evaporate with the chat. Skip entirely when `.tracker.followUps` is `off`.
Inside `/autopilot` this runs **once**, after the combined report — not after each phase.

## 1. Collect candidates — from this run only

Work that is real, specific and **not** part of what just shipped:
- scope you cut or deferred ("out of scope", "later", "separate PR"), and decisions you recorded that
  need a follow-through;
- review findings below the pass bar or left unfixed, and report-only QA / e2e findings on merged code
  (`/autoship` 5.5 / 5.6 — "fixes are follow-up PRs");
- gates that did **not** run because something is missing (a skill, a preview env, a dev sign-in route);
- test backdoors / fast paths you offered instead of adding (autodev Rules), and **Not verified
  locally** items that need real work to verify, not just a look after deploy;
- `TODO` / `FIXME` lines this diff added: `git diff <base>...HEAD | grep -E '^\+.*(TODO|FIXME)'`.

Not candidates: anything already done, vague wishes ("improve performance"), restatements of the PR,
items the operator already said no to.

## 2. Where they go

- **The backlog.** When the `mcp__backlog__*` tools resolve, `mcp__backlog__list_projects` with
  `repoPath` = the repo's main checkout (`git worktree list --porcelain | sed -n '1s/^worktree //p'`)
  gives this repo's projects — often several (a monorepo's sales / marketing / admin areas), each with
  a `scope`. That holds even while `.tracker` still names the tracker the repo is moving off; say so
  and suggest `/autopilot:init` to switch it.
- **Else `.tracker`** (`linear` / `jira` / `github` via its MCP or CLI), **else** nowhere: the drafts
  are printed.

## 3. Draft each one

- **Title** — imperative, ≤70 chars.
- **Brief** — self-contained, because it becomes the agent's prompt when the task is started later
  (for backlog, as the first message of a new Conductor workspace): the context with file paths,
  what to do, **done when**, and what not to touch. Name the PR / `<KEY>` it came from.
- **Project** — route by scope: the backlog project whose `scope` covers the files / area the task
  touches (`apps/backend/src/sales` → the sales project). Unclear between two → the closer one, with
  the other named in the why so the operator can redirect it. One project → it. Work that belongs to
  another repo goes to that repo's projects (`list_projects` with that repo's root). Without backlog
  projects: `.tracker.keyPrefix`.
- **Priority** — only when it's clear (a found regression is high; polish is low); else none.
- **Size** (backlog) — XS / S / M / L / XL, honestly: it picks how the task starts in Conductor —
  XS–S with `/autopilot:autopilot` (ships on its own), M+ with `/autopilot:autodev` (stops for a human
  to verify). Unsure → the larger one.
- **Duplicates** — search open issues first (backlog: `mcp__backlog__list_issues` with `query`); an
  existing match is shown as `already tracked: <KEY>`, not proposed again.

No candidates → a single `Follow-ups: none` line in the report, no question.

## 4. Propose — the operator picks

Print a numbered table (`# · title · project · size · priority · why`), then ask with `AskUserQuestion`
(`multiSelect: true`): up to 4 options per question, up to 4 questions — option label
`<title> → <PROJECT> · <size>`, description = the one-line why. More than 16 candidates → keep the strongest 16
and list the rest in text. No `AskUserQuestion` (headless / non-interactive run) → print the drafts as a
copy-pasteable block and **file nothing**.

**Never file a task the operator didn't pick** — a run that opens tickets on its own fills the board
with noise and overrides teams that reserve ticket creation for a human.

## 5. File the picked ones

- Backlog → `mcp__backlog__create_issue` with `project` (as routed, or as the operator redirected it),
  `title`, `description` = the brief, `priority`, `size`, and `followUpOf` = the issue this run was
  started for (`<KEY>`, the `Tracker issue:` line, or `list_issues` with `branch` = this branch) — the
  tracker links the two both ways.
- `linear` / `jira` / `github` → that tracker's create tool via `.tracker.mcp` (`github` without an MCP:
  `gh issue create --title … --body-file …`), with a "Follow-up of `<KEY>`" line at the top of the body.
- Nowhere to file, or the tracker isn't reachable → print the picked briefs as a copy-pasteable block.

Report line: `Follow-ups: filed SALES-12, MKT-4 · already tracked SALES-7 · not picked 2` (for backlog
issues, add each URL — it opens the issue, and **Start** there opens a new Conductor workspace).
