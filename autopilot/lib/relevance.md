# Is the task still relevant? (shared by /autodev, /autoship, /autopilot)

A task is a snapshot of what someone wanted when they wrote it. By the time a run starts, the work may
have landed on `<base>` without the ticket, be in flight in a parallel chat, have been canceled or
reshaped in the tracker's comments, or rest on code that's since gone. Building it anyway wastes the
run and ships a duplicate or a regression. So the **first** thing a run does — before planning, before
a single edit — is check, and when in doubt, **ask the operator**.

Runs **every time**: a task from the tracker or a typed description, with `--preloaded`, inside
`/autopilot`. Budget: a few minutes of reads — tracker calls, `git log` / `git grep`, `gh pr list`;
not a build.

## 1. Check (`/autodev`, before any work)

1. **The tracker** — when the task has a `<KEY>`: read the issue (backlog: `mcp__backlog__get_issue`;
   other trackers: their get tool via `.tracker.mcp`).
   - status `done` / `canceled` (or the tracker's equivalents), or its parent closed;
   - a later comment that retracts, replaces or narrows the task ("not needed", "done in …", "do X
     instead") — the latest word wins over the description;
   - the same work in another issue: search with two or three phrasings of the task (its key nouns,
     in the language the tracker's titles are written in), **without a status filter** (backlog:
     `mcp__backlog__list_issues` with `project` + `query`, one call per phrasing) — finished, in
     progress or in review elsewhere;
   - a parent: each open sub-issue its brief lists, the same way.
2. **The base branch** — `git fetch origin "<base>" -q`, then:
   - what landed since the task was filed — `git log --oneline --since="<issue createdAt>"
     origin/<base>` (a plan file: since its first commit; a description typed in this chat: skip) and
     `git log --oneline -i --grep "<KEY>" origin/<base>`;
   - the task's concrete hooks — the route, component, function, column, config key or error text it
     names — `git grep -n -i '<hook>' origin/<base> -- <paths>`: already does what's asked → done
     there; part of it → partly done.
3. **Open PRs** — `gh pr list --state open --search "<KEY>"` and once by the task's key nouns
   (`--json number,title,headRefName`); one on another branch already doing it → in flight.
4. **The premise** — what the brief rests on still holds on `<base>`: the files, routes, APIs and flows
   it names exist and behave as it says; for a bug, the faulty code or path it describes is still
   there. Read the code; reproduce only when that's one quick command.

## 2. Verdict

A doubt is **concrete evidence** from step 1 that you can point at (`<KEY>`, a sha, `#n`, `file:line`,
a comment and its date):
- the issue is closed, or a later comment retracts or reshapes it;
- the work is fully or partly on `<base>`, in an open PR, or in another issue;
- the premise broke — what the brief names is gone, renamed, or already behaves as asked; the bug's
  code is no longer there;
- the brief contradicts a newer decision — a later issue, a repo doc in `.rules.docs`.

**Not** a doubt: the task's age on its own, a terse brief, or how to build it — those are routine calls
(`/autodev` Rules: make them and record them).

**No doubt** → continue without a question. The handoff gets one line: `Relevance: checked — <what
you looked at, e.g. "issue open, nothing on main since 10-12 touches it, no open PR">`.

## 3. In doubt — ask, then wait

`AskUserQuestion`, one question: what's in doubt, then the evidence with its pointers. Options, those
that fit:
- **Continue as written** — the evidence is a false match;
- **Narrow to what's missing** — when part is done: say what's left;
- **Close the issue** — `done` (it's already there) or `canceled` (no longer wanted), with the
  evidence in a comment (backlog: `mcp__backlog__update_issue` + `mcp__backlog__add_comment`; other
  trackers via `.tracker.mcp`, else name it in the report);
- **Stop, change nothing.**

A free-form answer (a new scope, a different approach) overrides the options. Record the answer in
the handoff (`Relevance: narrowed to … — operator's call`); with a `<KEY>`, a changed scope also goes
on the issue as a comment, so the tracker shows why. Narrowed → the narrowed task is the spec from
here on.

**Close** or **stop** ends the run right there: no branch work, no PR, no follow-ups — one line on
what was found and what the operator chose.

**No `AskUserQuestion`** (headless / non-interactive run) → don't build: print the question with its
evidence and STOP.

## 4. Re-check before shipping (`/autoship`)

The work exists by now, so check only what can change while a PR waits — per PR, in Step 0, before
anything merges:
- **the tracker** — the issue went `canceled`, or `done` while this PR is unmerged, or a comment newer
  than the PR (`gh pr view <PR> --json createdAt`; no PR yet: the branch's first commit), other than
  the runs' own notes, retracts or reshapes the task;
- **the base branch** — the same change landed through another PR: `git fetch origin "<base>" -q`,
  `git log --oneline -i --grep "<KEY>" "$(git merge-base HEAD origin/<base>)..origin/<base>"` (another
  repo's PR: `git -C <dir>`) and `gh pr list --state merged --search "<KEY>" --json
  number,title,headRefName` (other branches only).

Nothing → ship on. Evidence → ask as in step 3, one question covering every
such PR: **Ship it**, **Close the PR** (`gh pr close <PR> --comment "<why>"`) or **Hold, change
nothing**. Close or hold leaves out that PR and the PRs that depend on it; the rest ship.
