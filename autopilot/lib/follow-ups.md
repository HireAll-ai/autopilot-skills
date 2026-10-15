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

## 2. Draft each one

- **Title** — imperative, ≤70 chars.
- **Brief** — self-contained, because it becomes the agent's prompt when the task is started later
  (with `backlog`, as the first message of a new Conductor workspace): the context with file paths,
  what to do, **done when**, and what not to touch. Name the PR / `<KEY>` it came from.
- **Project** — default: this repo's project (`.tracker.keyPrefix`). Work that belongs to another repo
  goes to that repo's project — with `backlog`, find it via `<mcp>__list_projects` with `repoPath`.
- **Priority** — only when it's clear (a found regression is high; polish is low); else none.
- **Duplicates** — search open issues first (`backlog`: `<mcp>__list_issues` with `query`); an
  existing match is shown as `already tracked: <KEY>`, not proposed again.

No candidates → a single `Follow-ups: none` line in the report, no question.

## 3. Propose — the operator picks

Print a numbered table (`# · title · project · priority · why`), then ask with `AskUserQuestion`
(`multiSelect: true`): up to 4 options per question, up to 4 questions — option label
`<title> → <PROJECT>`, description = the one-line why. More than 16 candidates → keep the strongest 16
and list the rest in text. No `AskUserQuestion` (headless / non-interactive run) → print the drafts as a
copy-pasteable block and **file nothing**.

**Never file a task the operator didn't pick** — a run that opens tickets on its own fills the board
with noise and overrides teams that reserve ticket creation for a human.

## 4. File the picked ones

- `backlog` → `<mcp>__create_issue` with `project`, `title`, `description` = the brief, `priority`,
  and `followUpOf: <KEY>` when this run has a key (the tracker links the two both ways).
- `linear` / `jira` / `github` → that tracker's create tool via `.tracker.mcp` (`github` without an MCP:
  `gh issue create --title … --body-file …`), with a "Follow-up of `<KEY>`" line at the top of the body.
- `none`, or the tracker MCP isn't reachable → print the picked briefs as a copy-pasteable block.

Report line: `Follow-ups: filed TASK-12, TASK-13 · already tracked TASK-7 · not picked 2` (with
`backlog`, add each new issue's URL — it opens the issue, and **Start** there opens a new workspace).
