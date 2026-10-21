# autopilot-skills

A Claude Code plugin marketplace for **autopilot** — project-independent autonomous-dev commands.

Every run first checks that the task is still relevant — not already on the base branch, in flight
elsewhere, closed or retracted in the tracker — and asks when in doubt.

- **`/autodev`** — plan → implement → test → local quality gate (+ opt-in `--e2e`, on video with
  `--video`) → **draft PR**, then STOP for verification. Never ships.
- **`/autoship`** — flip the draft to ready → loop the auto-reviewer to its pass bar → required checks
  green → repo-aware merge → deploy canary → optional `--qa`/`--e2e` → move the ticket to the ship status.
  Ships every PR the chat opened, across repos — each under its own repo's config.
- **`/autopilot`** — `/autodev` + `/autoship` back-to-back, no verification stop.

The command **logic is here**; everything **project-specific** lives in a committed
`.claude/autopilot.config.json` in each consuming repo (ticket prefix, package-manager commands, base
branch + protection, review gate, deploy targets, QA). Install once, adapt per repo via that config —
no copy-editing of command bodies.

## Install

```bash
claude plugin marketplace add HireAll-ai/autopilot-skills
claude plugin install autopilot@autopilot-skills
```

Then `/autodev`, `/autoship`, `/autopilot` resolve in any project (run `/autopilot:init` once per repo first). On the first run in a repo without a
config, they **autodetect + confirm** and write `.claude/autopilot.config.json` (commit it — the whole
team then reuses it). Update the plugin with `claude plugin marketplace update autopilot-skills`.

## Per-repo config

See [`autopilot/README.md`](autopilot/README.md) and the JSON Schema at
[`autopilot/schema/autopilot.config.schema.json`](autopilot/schema/autopilot.config.schema.json).
Preview the autodetect for the current repo without writing:

```bash
"$(claude plugin root autopilot 2>/dev/null || echo autopilot)"/lib/autopilot-config.sh detect
```

## Video recording (opt-in)

`--e2e` runs can be recorded (Playwright → mp4 for the chat, gif for the PR, and the video attached to
the backlog issue) — `--video` for one run, `qa.video.enabled` for every run. Playwright + ffmpeg are
soft deps — installed once in `~/.autopilot/playwright`, Playwright survives plugin updates; without them
the recorder degrades (falls back to the non-video pass, or keeps `.webm`). See the plugin README.

## CI

[`.github/workflows/check.yml`](.github/workflows/check.yml) runs on every PR and on pushes to `main`,
on `ubuntu-latest` and `macos-latest`: the typecheck read from `.claude/autopilot.config.json`
(`.commands.typecheck`, piped to `bash`, so CI and the local gate can't drift apart), then
`autopilot/test/stacked-merge.sh` — on macOS a second time under `/bin/bash` 3.2. Its two jobs,
`check (ubuntu-latest)` and `check (macos-latest)`, are this repo's `.git.protection.requiredChecks`;
rename them in both places. Whether branch protection on `main` requires them is a maintainer's call.

## Layout

```
.github/workflows/check.yml         # CI: typecheck + stacked-merge.sh on Linux and macOS (bash 3.2 too)
.claude-plugin/marketplace.json     # this marketplace, lists the autopilot plugin
autopilot/                          # the plugin
  .claude-plugin/plugin.json
  commands/{init,autodev,autoship,autopilot}.md # reference ${CLAUDE_PLUGIN_ROOT}/lib/...
  lib/autopilot-config.sh                     # config loader (load/ensure/get/detect/validate)
  lib/typecheck.sh                            # typecheck, cached per working tree
  lib/verify-deploy.sh                        # /autoship Step 5.1 deploy proof (background)
  lib/config-interview.md, lib/e2e.md         # read on demand (first run / --e2e only)
  lib/relevance.md                            # start-of-run relevance check (every run)
  lib/follow-ups.md                           # end-of-run follow-up tasks (read on demand)
  lib/record-e2e.mjs                          # Playwright scenario runner + video
  schema/autopilot.config.schema.json
  test/stacked-merge.sh, test/bin/gh          # local check of /autoship's stack merge (bare repo + gh stub)
  README.md
```

MIT licensed.
