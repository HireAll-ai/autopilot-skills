# autopilot (plugin)

Project-independent `/autodev`, `/autoship`, `/autopilot`. The command bodies contain **no**
project-specific literals — they read `.claude/autopilot.config.json` (per-repo, committed) at Step 0.0.
Bundled scripts are referenced via `${CLAUDE_PLUGIN_ROOT}`, so the plugin works from wherever Claude
Code installs it.

## Install

```bash
claude plugin marketplace add HireAll-ai/autopilot-skills
claude plugin install autopilot@autopilot-skills
```

## First run (per repo) — detect + confirm

On the first `/autodev` (or `/autopilot`) in a repo with no config, Step 0.0 autodetects and asks you
to confirm/fill the gaps, then writes + `git add`s `.claude/autopilot.config.json`. Autodetected:
package-manager commands (lockfile + `package.json` scripts), base branch + protection
(`gh api …/branches/<base>/protection`), ticket prefix (commit history), and a health/deploy URL.
You confirm the rest: tracker type + MCP + ship status, review gate, deploy URLs, whether to enable
video. Re-run any time with `--reconfigure`.

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
skills + `video`), `rules` (which repo docs to obey + plan/spec dirs + PR template).

A consuming repo's config commonly starts with:

```json
{
  "$comment": "Consumed by the autopilot plugin — claude plugin marketplace add HireAll-ai/autopilot-skills",
  "version": 1,
  "tracker": { "type": "jira", "keyPrefix": "PROJ", "keyRequired": true, "shipStatus": "In Review" },
  "...": "see the schema"
}
```

## Video recording (opt-in)

When `qa.video.enabled` is true, the `--e2e` scenario walk is recorded via `lib/record-e2e.mjs`
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

## Requirements

`git`, `gh`, `jq` required. `ffmpeg` optional (mp4/gif). `playwright` optional (video). `node` for the recorder.
