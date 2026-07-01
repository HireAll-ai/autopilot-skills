# autopilot-skills

A Claude Code plugin marketplace for **autopilot** — project-independent autonomous-dev commands.

- **`/autodev`** — plan → implement → test → local quality gate (+ opt-in `--e2e`, recorded to video) →
  **draft PR**, then STOP for verification. Never ships.
- **`/autoship`** — flip the draft to ready → loop the auto-reviewer to its pass bar → required checks
  green → repo-aware merge → deploy canary → optional `--qa`/`--e2e` → move the ticket to the ship status.
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

Then `/autodev`, `/autoship`, `/autopilot` resolve in any project. On the first run in a repo without a
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

`--e2e` runs can be recorded (Playwright → mp4 for the chat, gif for the PR). Playwright + ffmpeg are
soft deps — without them the recorder degrades (falls back to the non-video pass, or keeps `.webm`).
See the plugin README.

## Layout

```
.claude-plugin/marketplace.json     # this marketplace, lists the autopilot plugin
autopilot/                          # the plugin
  .claude-plugin/plugin.json
  commands/{autodev,autoship,autopilot}.md   # reference ${CLAUDE_PLUGIN_ROOT}/lib/...
  lib/autopilot-config.sh                     # config loader / autodetect / validate
  lib/record-e2e.mjs                          # Playwright scenario runner + video
  schema/autopilot.config.schema.json
  README.md
```

MIT licensed.
