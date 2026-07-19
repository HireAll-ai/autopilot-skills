---
name: factory
description: Send a task to the software factory (fabro pipeline) — pick a lane, launch the run, watch it, and surface human gates to the operator. Use when the user says "запусти фабрику", "отправь в фабрику", "factory run", or gives a build/fix task meant for autonomous end-to-end delivery instead of interactive editing.
---

# Software Factory dispatch

The factory is a set of fabro workflow lanes committed to the product repo.
Your job here is dispatch, monitoring, and translation — the pipeline does the
building; the operator answers the gates.

## 0. Preflight (this repo, this machine)

0. Initialized? `.claude/autopilot.init.json` must exist. If not — **stop** and
   tell the user to run `/autopilot:init` first (verifies/installs gstack,
   scaffolds the factory, bootstraps DESIGN.md + baseline docs). The lanes
   delegate to gstack skills (/qa, /cso, /document-release), so dispatching
   without init produces degraded runs.
1. Factory scaffold present? `.fabro/workflows/` and `factory/` must exist in
   the repo root. If absent — this repo is not factory-enabled: offer to run
   `/factory-init` (scaffolds lanes, hooks, and e2e machinery from the plugin).
2. fabro reachable? `fabro server status || fabro doctor`. Remote server:
   respect `$FABRO_SERVER` (e.g. `https://fabro.<domain>` once the factory runs
   on Hetzner). Install if missing: `brew install fabro-sh/tap/fabro-nightly`.
3. Dev token (for raw API calls only):
   `grep -o 'fabro_dev_[a-f0-9]*' ~/.fabro/storage/server.env`.

## 1. Pick a lane (30-second rules; details in the repo's factory/README.md)

1. Dictated tweak, wrong result costs only a rerun, no data/auth/payments → `express-lane`
2. "Know it right when I click it" (UX/feel) → `iterate-lane`
3. New capability, expensive-to-undo decisions, or 30+ min autonomous work → `feature-pipeline`.
   Two composable input flags (the old `feature-quick` lane is merged in here):
   - user says «без спеки» / "skip the spec" / --no-spec → add `-I no_spec=true`:
     no spec document; the agent asks only the key implementation questions
     (with recommendations) at a single details gate.
   - user says «не хочу читать спеку» / "auto-approve the plan" / --auto → add
     `-I auto=true`: an independent autoplan reviewer resolves the plan
     decisions itself; Gate 1 opens only for operator-only decisions
     (data model, auth, payments, public APIs, taste). Gate 2 stays human.
4. Bug, cause obvious + reproducible → `bugfix-express`; cause unclear / wide blast radius → `bugfix-deep`

Tell the user which lane you picked and why (one sentence). If genuinely
ambiguous, ask with the two candidate lanes as options.

## 2. Launch

```bash
fabro create .fabro/workflows/<lane>/workflow.toml --goal "<task, specific and testable>" \
  [-I no_spec=true] [-I auto=true]     # feature-pipeline modes only
fabro start <run-id>
```

`fabro run <lane> --goal "..."` works too but blocks the shell; prefer create+start.

## 3. Watch and surface gates

Poll in a background shell (30s interval) until status is `blocked`,
`succeeded`, or `failed`:

```bash
fabro inspect <run-id> --json   # status.kind
fabro events <run-id> | tail    # current stage
```

- On `blocked` (human_input_required): tell the operator the gate question, the
  digest/artifacts from the gate context (`current_question` in inspect JSON,
  ACCEPTANCE ARTIFACTS / VIDEOS.md in the stage output), preview URL, and the
  run link `<server>/runs/<run-id>`. NEVER answer a gate yourself.
- On `failed`: read `fabro events` tail, summarize the failing stage, offer
  `fabro resume` after a fix or a rerun.
- On `succeeded`: report the run summary (what shipped, commits, artifacts, cost).

## 4. Cautions

- With the local sandbox provider, runs execute in this repo's checkout: don't
  edit the same files interactively while a run's implement stage is active.
- Gates are the operator's; never click or answer them autonomously.
- Artifacts land in `factory-artifacts/<run-id>/` (videos + VIDEOS.md map).
