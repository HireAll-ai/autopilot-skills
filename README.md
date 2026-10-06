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

`--e2e` runs can be recorded (Playwright → mp4 for the chat, gif for the PR). Playwright + ffmpeg are
soft deps — without them the recorder degrades (falls back to the non-video pass, or keeps `.webm`).
See the plugin README.

## Layout

```
.claude-plugin/marketplace.json     # this marketplace, lists the autopilot plugin
autopilot/                          # the plugin
  .claude-plugin/plugin.json
  commands/{init,autodev,autoship,autopilot,factory-init}.md   # reference ${CLAUDE_PLUGIN_ROOT}/lib/...
  skills/factory/SKILL.md                     # /factory dispatch
  lib/autopilot-config.sh                     # config loader (load/ensure/get/detect/validate)
  lib/typecheck.sh                            # typecheck, cached per working tree
  lib/verify-deploy.sh                        # /autoship Step 5.1 deploy proof (background)
  lib/config-interview.md, lib/e2e.md         # read on demand (first run / --e2e only)
  lib/record-e2e.mjs                          # Playwright scenario runner + video
  lib/factory-scaffold/                       # snapshot copied by /factory-init
  schema/autopilot.config.schema.json
  README.md
```

MIT licensed.
