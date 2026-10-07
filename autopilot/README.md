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

1. verifies **gstack** is installed (installs it if missing) — the factory lanes and QA/review/canary
   steps delegate to gstack skills (`/qa`, `/cso`, `/design-consultation`, `/document-generate`, …);
2. ensures `.claude/autopilot.config.json` (same detect-and-confirm interview as below);
3. scaffolds the **software factory** via `/factory-init` when the fabro CLI is available;
4. bootstraps the **design system** — gstack `/design-consultation` → `DESIGN.md` (UI products);
5. bootstraps **baseline documentation** — gstack `/document-generate` (Diataxis baseline);
6. writes the `.claude/autopilot.init.json` marker and commits.

Idempotent; flags: `--force`, `--skip-design`, `--skip-docs`, `--skip-factory`.

## Config — detect + confirm

On the first `/autodev` (or `/autopilot`) in a repo with no config, Step 0.0 autodetects and asks you
to confirm/fill the gaps, then writes + `git add`s `.claude/autopilot.config.json`. Autodetected:
package-manager commands (lockfile + `package.json` scripts), base branch + protection
(`gh api …/branches/<base>/protection`), ticket prefix (commit history), and a health/deploy URL.
You confirm the rest: tracker type + MCP + ship status, review gate, deploy URLs, whether to enable
video. Re-run any time with `--reconfigure`.

The commands load it with **one** call at Step 0.0 — `autopilot-config.sh load` checks the init marker
(exit 4 if missing) and prints the config (exit 0) or an autodetected draft (exit 3) to stdout, so the
agent reads the config once into context instead of re-querying it per value. The interview itself
lives in [`lib/config-interview.md`](lib/config-interview.md) and is only read when needed.

Preview / inspect via the loader (resolve the plugin dir with `claude plugin root autopilot`):

```bash
PLUGIN="$(claude plugin root autopilot)"     # e.g. ~/.claude/plugins/.../autopilot
"$PLUGIN/lib/autopilot-config.sh" detect      # print an autodetected draft
"$PLUGIN/lib/autopilot-config.sh" validate     # check the written config
"$PLUGIN/lib/autopilot-config.sh" get '.git.baseBranch'
```

## Config reference

Full contract: [`schema/autopilot.config.schema.json`](schema/autopilot.config.schema.json). Sections:
`tracker` (issue tracker + ship status), `git` (base branch, merge strategy, protection), `commands`
(install/typecheck/test/build/dev — empty string = "skip this step"), `review` (auto-reviewer gate +
pass bar + local reviewers), `deploy` (trigger, healthcheck, env URLs, canary skill), `qa` (browser
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

## Runtime helpers

| script | used by | what it saves |
|---|---|---|
| `lib/typecheck.sh` | every `<typecheck>` gate in `/autodev` + `/autoship` | runs `.commands.typecheck` at most once per working tree (cache keyed by tree hash under the per-worktree git dir), so re-asserting the gate after a no-op rebase/push is free |
| `lib/verify-deploy.sh <merge-sha>` | `/autoship` Step 5.1 | one background call per `.deploy.verify.mode`; `github-run` filters to `.deploy.verify.workflow` (else every push run for the SHA must go green). Exit 0 verified / 1 broken / 10 unverified / 12 commit unknown |

Long waits (CI watch, merge queue, deploy verify) are run with `run_in_background` — the Bash tool caps
foreground calls at 10 minutes. `/autodev`'s local reviewers and QA run as **parallel report-only
subagents**; the main agent applies the fixes. `/autopilot` loads the config once and passes
`--preloaded` to both phases.

**Tracker MCP permissions.** `allowed-tools` can't follow the configured tracker, so only the Jira
server tools are pre-approved. For another tracker (e.g. Linear), add its MCP server to the consuming
repo's `.claude/settings.json` → `permissions.allow` (e.g. `"mcp__linear"`) so `/autoship` Step 6
doesn't stop on a permission prompt.

## Video recording (opt-in)

The `--e2e` procedure (scenarios, recorder exit codes, fix-loop vs report-only, video surfacing) lives in
[`lib/e2e.md`](lib/e2e.md) and is only read when `--e2e` is passed. When `qa.video.enabled` is true, the `--e2e` scenario walk is recorded via `lib/record-e2e.mjs`
(standalone Playwright — independent of any project browser tooling):

```bash
node "$(claude plugin root autopilot)/lib/record-e2e.mjs" scenario.json \
  --out-dir .context/video --format mp4 --gif --base-url http://localhost:5173 --max-seconds 90
```

- **Scenario** = JSON with `steps` (`goto`/`fill`/`click`/`press`/`waitFor`/`expect`/`screenshot`/`wait`).
- **Output**: a `.webm` always; `.mp4`/`.gif` when **ffmpeg** is installed (else the `.webm` is kept —
  GitHub and Chromium play webm). `--gif` adds a gif alongside the primary format.
- **Playwright** is a soft dep (`npm i playwright && npx playwright install chromium`, in your project
  or the plugin dir). Missing → the recorder exits **2** and the e2e step falls back to the non-video
  browser pass. Exit **3** = scenario/usage error (fix + re-run, no fallback).
- **Surfacing** (`qa.video.surface`): `context` → artifact under `.context/` referenced in the handoff
  (renders in the Conductor chat; gif previews inline); `pr-gif` → a committed gif referenced by raw
  URL in the PR body (GitHub can't embed API-uploaded video); `both`; `none`.

## Verification handoff (`/autodev`)

`/autodev` stops for a human to verify, so it hands over something clickable rather than a
paragraph: a **live preview link** to the running dev server (URL read from the server's own
output, `curl`-checked before it's printed, the server left up), routed through
`qa.preview.authPath` (e.g. `/dev-login`) so the link lands past the login wall and on the changed
surface — plus a **test plan** at `.context/testplan-<KEY>.md`: 5–10 `do X → expect Y` checks, what
could **not** be verified locally, and where to look when it's wrong.

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

`git`, `gh`, `jq` required. `ffmpeg` optional (mp4/gif). `playwright` optional (video). `node` for the recorder.
