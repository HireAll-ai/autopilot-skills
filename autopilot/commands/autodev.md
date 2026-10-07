---
description: Autonomous feature build that ends in a verified handoff — you decide how to plan, build and test; the command fixes what must be true when you stop — tests green per the repo's strategy, local review + browser QA done (or --e2e scenarios, optionally on video), a live preview link and a test plan, and a DRAFT PR with CI pre-warmed. Then STOPS for your verification. Never ships — a draft PR is not mergeable. Project-independent: reads .claude/autopilot.config.json.
argument-hint: "[spec/plan file | feature description] [--e2e] [--reconfigure]"
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, Skill, TodoWrite, Agent, AskUserQuestion, WebFetch
---

# /autodev — build it, prove it, hand it over (never ships)

Run this when intent and scope are clear (typically after brainstorming / `/office-hours`).
Pipeline: brainstorm → **`/autodev`** → *(you verify)* → `/autoship`.

This command defines **what must be true when you stop**, not how to get there. How deep to plan,
whether to explore with subagents, which skills to lean on, how to slice commits and tests — your
call, sized to the task. The parts spelled out below are the ones that are non-obvious or that the
rest of the pipeline (`/autoship`, the human) depends on.

Input (`$ARGUMENTS`, optional):
- A spec/plan file path or a short feature description. Omitted → this conversation's brainstorm output.
- `--e2e` — scenario browser e2e instead of the heuristic QA pass (one browser pass, not two),
  recorded to video when `.qa.video.enabled`.
- `--reconfigure` — re-run the config interview even if a config exists.
- `--preloaded` — internal, passed by `/autopilot`: Step 0.0 already ran, the config is in context.

## Step 0.0 — Init check + load project config (one call)

Skip when `$ARGUMENTS` has `--preloaded`.

```bash
"${CLAUDE_PLUGIN_ROOT}/lib/autopilot-config.sh" load; echo "rc=$?"     # add --reconfigure if passed
```
- **rc=0** → stdout **is** the config — read once, keep it in context.
- **rc=4** → `NOT_INITIALIZED` → **STOP**: tell the user to run **`/autopilot:init`** first, then re-run.
- **rc=3** → no config (or `--reconfigure`): Read `${CLAUDE_PLUGIN_ROOT}/lib/config-interview.md`,
  run it, continue.
- **rc=2 / other** → loader error on stderr (commonly: `jq` missing) → surface it, **STOP**.

Shell state does not persist between Bash calls — substitute config values literally. Placeholders:
`<KEY>` = `<keyPrefix>-NNN`, always upper-case, `<base>` = `.git.baseBranch`, `<dev>` / `<test>` =
`.commands.*`; an empty command means *not applicable — skip it and say so*. **`<typecheck>`** =
`"${CLAUDE_PLUGIN_ROOT}/lib/typecheck.sh"` (cached per working tree, so repeating it is free).

**`<subject>`** = a commit subject or the PR title, shaped by `.git.commitStyle` (absent =
`key-prefix`). The repo's history and tooling (changelogs, commit linters) parse these, so the style
is the repo's, not yours:
- `key-prefix` → `<KEY>: <what + why>`.
- `conventional` → `type(scope): summary` — Conventional Commits 1.0: a lower-case type (`feat`,
  `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `ci`, `chore`; a commit-linter config in the
  repo has the last word), optional scope, `!` for a breaking change, imperative, ≤72 chars, **no key
  in the subject**. The key goes in a `Refs: <KEY>` trailer on each commit and a `Ticket: <KEY>` line
  in the PR body. The PR title becomes the squash subject, so it follows the same rule.

No key (tracker `none`, or optional and absent) → drop the key parts; never a dangling `: ` or `Refs:`.

**Preflight.** On `<base>` → **STOP** and ask to branch first (in Conductor: a fresh workspace),
suggesting a name from `.git.branchPattern`: `{key}` = `<KEY>`, `{key_lower}` = `<KEY>` lower-cased
(`pos-42`), `{slug}` = a short kebab-case summary. Find the key in a branch name case-insensitively —
`pos-42-…` carries `POS-42`. If `.tracker.keyRequired` and the branch carries no `<KEY>`: **ask** for
it — **never invent a key**. Create the issue via `.tracker.mcp` yourself only when
`.tracker.autoCreateIssue` is `true` and the work clearly has none; many repos reserve opening tickets
for a human. A branch name you can't change is fine; carry `<KEY>` in commits and the PR.

## Rules (hold throughout)

- **The repo decides how.** Obey the docs in `.rules.docs` (architecture, standards, testing
  strategy, UI and 3rd-party-API policy). This command doesn't restate them.
- **Tests: what the repo's Testing Strategy calls for — no slop.** Work with no runtime logic
  (pure config/data-model/tooling) may have none; say so. If those docs prescribe "ask before writing
  tests", invoking `/autodev` is that opt-in — write them now; they're reviewed with the code at the
  handoff.
- **Commits** — `<subject>`, intentional staging. `<typecheck>` green before every push.
- **Never ship.** Draft PR only: never mark it ready, merge, deploy, or move the ticket.
- **No test backdoors in product code** (prefill routes, auth bypasses) just to make verification
  easier — offer them as a follow-up instead.
- **Autonomy.** Run to completion without check-ins; make routine calls yourself and record them for
  the handoff. **STOP and ask** only on: an architecture fork with no clear winner; destructive or
  irreversible scope; a 3rd-party API contract you can't confirm from docs (WebFetch / context7 first).
- **Gates named in config are load-bearing** — `.review.localReviewers`, `.qa.qaOnlySkill` (else
  `.qa.qaSkill`), `.qa.browseSkill`. One that's configured but doesn't resolve means that gate did
  **not** run: say so in the handoff. Don't install skills mid-run.

## Done means — verify every item before the handoff

1. **Built** — the feature as specified, committed on the branch.
2. **Green** — `<typecheck>` and `<test>` (or the targeted `.commands.testFilter`) pass.
3. **Reviewed** — every `.review.localReviewers` entry ran on `git diff <base>...HEAD`; its
   high-confidence findings are fixed.
4. **Browser-checked (UI changes)** — `.qa.qaOnlySkill` ran against the local dev server, scoped to
   the touched flows, and the bugs it found are fixed and re-verified. With `--e2e`, instead: Read
   `${CLAUDE_PLUGIN_ROOT}/lib/e2e.md` and run its **local** mode (≤3 fix attempts per scenario). A UI
   that can't run locally, or a scenario still red, is a **blocker** in the handoff — never green.
5. **Clickable** — a live preview link + `.context/testplan-<KEY>.md` (below).
6. **Draft PR** — open, template complete, CI running.

### Mechanics that matter

**3 + 4 run as parallel, report-only subagents.** Start `<dev>` in the background first so QA gets a
warm URL. Then one `Agent` per pass, **all in one message**; each prompt: *"In `<repo path>`, invoke
`<skill>` on `git diff <base>...HEAD` (QA: against `<url>`, the flows this diff touches). REPORT ONLY —
don't edit, commit or push. Return severity, confidence, file:line, problem, suggested fix (QA: + repro
steps, screenshots). If the skill doesn't resolve, say so and stop."* Concurrent writers clobber one
tree, so **you** own every fix; afterwards re-verify only the fixed UI bugs with `.qa.browseSkill`.

**Preview link.**
- Take the URL the server **actually printed** — never assume a port. `.qa.preview.url` overrides
  (resolve an env-var value at run time). `curl -fsS -o /dev/null -w '%{http_code}' <url>` must be
  2xx/3xx; a dead link is a blocker, not a link.
- Land on **the changed surface**, signed in: route through `.qa.preview.authPath` when set (chain the
  target as its redirect param, else hand over both links in order). If QA/e2e didn't already drive
  that route, walk it once with `.qa.browseSkill`.
- When reaching the state under test takes more than ~3 manual steps or needs data a fresh DB lacks,
  add a **fast-path link**: an existing deep link, else a scratch seed script under `.context/` that
  creates the fixture and prints its URL (hand over the link + the re-seed command).
- Leave the server running and include the restart command. *(From `/autopilot`: don't hold it open.)*

**Test plan** `.context/testplan-<KEY>.md` — 5–10 `do X → expect Y` checks for what this change
claims (happy path → the branches it introduces → neighbours it could regress), plus **Not verified
locally** (3rd-party callbacks, prod-only data — watch these after `/autoship`) and **If it looks
wrong** (which log / table / endpoint first). Don't re-test what unit tests cover. *(From
`/autopilot`: still write it — it's the post-deploy checklist.)*

**Draft PR.** `git push -u origin HEAD`. Body: `.rules.prTemplate` with **every** section filled
(None/N/A allowed — context is hot now, and `/autoship` reuses it), plus the `Ticket: <KEY>` line
under `conventional`, in a temp file; `gh pr create --draft --base <base> --title "<subject>"
--body-file <tmp>`. Re-run → push and `gh pr edit` the existing PR instead of opening a second. No
manual review trigger: the auto-reviewer runs once `/autoship` flips the PR to ready.

## Handoff — print, then STOP

```
/autodev — ready for your verification (NOT shipped).
  Ticket:    <KEY> (<tracker>)            Draft PR: #<n> — NOT mergeable, CI running
  Built:     <one line>                   Plan: <file | inline>
  Decisions: <calls made autonomously>
  Checks:    typecheck ✓ | tests <N ✓ | none: why> | review <reviewers ✓> | browser <qa ✓ | e2e N✓ M✗ | n/a>
             gates that did NOT run: <none | which + why>
  Video:     <paths | gif in PR | n/a>
  Risks:     <open questions, blockers>

  TEST IT
    Preview:    <url — signed in, on the feature | command/curl for non-UI work>
    Fast path:  <url + re-seed cmd | n/a>
    Server:     <running here — keep this session open> | restart: <dev> → <url>
    Test plan:  .context/testplan-<KEY>.md — first checks:
                  1. <do X → expect Y>   2. <…>   3. <…>
    Not verified locally: <bullets | none>

  Looks right → /autoship  (--qa: QA the deployed build; --e2e: scenario e2e on the deployed env)
```

Do not continue past this gate — wait for the user.
