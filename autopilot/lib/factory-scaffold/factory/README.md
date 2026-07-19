# Software Factory

Autonomous spec-to-deploy pipeline with human gates, orchestrated by
[fabro](https://github.com/fabro-sh/fabro). Claude Code + gstack act as
executors inside stages; Coolify/DO provide preview and prod deploys.

## Lanes — which workflow for which task

Five lanes, one shared ship path (tests → PR → merge → prod video). They
differ in what plays the role of the spec and in how much operator attention
they consume:

| Lane | Task type | "Spec" is… | Human gates | Preview | Review |
|---|---|---|---|---|---|
| `express-lane` | dictated tweak: move/hide a button, copy change | the goal sentence itself | **0** | — | — (tests only) |
| `iterate-lane` | "know it when I see it": UX, layout, product feel | the feedback loop | N × Feedback / Done | every round + walkthrough video | full, after Done |
| `feature-pipeline` | big feature, long autonomous block (30 min+) | `spec.md` + `design.html` | 2 (spec, accept) | once, with e2e video | full |
| `feature-quick` | same scale, but no spec document — operator only answers implementation questions | the goal + answered questions | 2 (details, accept) | once, with e2e video | full |
| `bugfix-express` | bug with obvious cause + repro | the failing repro test | **0** | — | — (tests only) |
| `bugfix-deep` | unclear cause, wide blast radius, incidents | `rootcause.md` (evidence chain) | 2 (diagnosis, accept) | once, e2e of broken flow | full, regression-focused |

**Choosing (30-second rules):**

1. Can you dictate the change in one message, and a wrong result costs only
   another run (no data/auth/payments touched)? → `express-lane`.
2. You'll only know it's right when you click it? → `iterate-lane`.
3. New capability with decisions that are expensive to undo (data model,
   APIs, integrations), or hours of autonomous work? → `feature-pipeline`.
   Same, but you don't want a spec document — just answer a short list of
   implementation questions (`--no-spec`)? → `feature-quick`.
4. Bug: cause obvious and reproducible? → `bugfix-express`.
   Cause unclear, or the fix could regress neighbors? → `bugfix-deep`.

Tie-breakers: doubt about **what to build** → iterate-lane; doubt about
**what might break** → the heavier lane. Picking too light a lane is
recoverable: express lanes carry an ESCAPE HATCH — the agent refuses to merge
anything bigger than its lane (data model/auth/payments/&gt;~150 lines, or a
non-obvious root cause), writes `escalate.md`/`triage.md` and stops, and the
summary names the lane to rerun in. Picking too heavy only costs your time at
gates, never correctness.

Rendered graphs: `factory/workflows/<lane>.svg`.

## Feature pipeline (`factory/workflows/feature-pipeline.dot`)

```
spec ──▶ [Gate 1: Approve Spec] ──▶ implement ──▶ tests ──▶ (fix loop)
                                        │
              preview deploy ◀──────────┘
                    │
              e2e + video ──▶ [Gate 2: Accept / Steer / Rework]
                    │
              PR ──▶ cross-review ──▶ fixes ──▶ merge ──▶ prod e2e + video
```

- **Gate 1** — approve the spec; `spec.md` includes a "Key decisions" section
  with everything the agent can't choose alone. `[R] Revise` loops back with
  your freeform feedback.
- **Gate 2** — accept the feature after watching the e2e video and clicking
  through the preview deploy. `[S] Steer` sends freeform notes back to the
  implementing agent; `[R] Rework Spec` restarts from the spec.
- Rendered graph: `factory/workflows/feature-pipeline.svg`
  (regenerate: `fabro graph factory/workflows/feature-pipeline.dot -o ...`).

## Other lanes (structure deltas vs feature-pipeline)

- **`express-lane`** — implement → scope check → tests → PR → merge →
  prod smoke video → summary. No spec, no gates, no cross-review; the agent
  is prompted to be conservative (smallest diff, no refactoring) because
  nothing human stands before merge. Failure mode is fix-forward.
- **`iterate-lane`** — increment → suite green → preview → walkthrough
  video of the round (`round-video.sh`, non-blocking demo artifact:
  `factory-artifacts/<run>/round-N/`) → `[D] Done / [F] Feedback` gate
  looping back into one shared thread (context accumulates across rounds,
  `max_visits=20`). The gate shows a `ROUND N ARTIFACTS` block with the
  preview URL and video. Tests are written once, after Done, against the
  settled behavior; the last round's video doubles as the acceptance
  artifact, then PR → review (also hunts dead ends left by abandoned
  rounds) → merge → prod e2e.
- **`bugfix-express`** — reproduce (failing test first, commit it) → fix →
  tests → PR → merge → prod smoke. Repro and fix share a thread. Cannot
  reproduce / cause non-obvious ⇒ ESCALATE to `bugfix-deep`.
- **`bugfix-deep`** — investigate (evidence chain, blast radius, fix options
  in `rootcause.md`) → Gate 1 approves the *diagnosis and plan* → fix +
  regression tests across the blast radius → preview e2e video of the broken
  flow → Gate 2 → PR → review (hunts regressions and symptom-patching) →
  merge → prod e2e → post-mortem instead of a plain summary.

## Per-product hooks (`factory/hooks/`)

| Hook | Purpose | Config |
|---|---|---|
| `run-tests.sh` | test suite | `FACTORY_TEST_CMD` (else autodetect npm/cargo/pytest) |
| `preview-deploy.sh` | branch preview | `FACTORY_PREVIEW_PLATFORM=coolify\|do`, `COOLIFY_URL/TOKEN/APP_UUID`, `PREVIEW_DOMAIN` |
| `e2e-video.sh` | acceptance e2e vs preview; fails on unmet criteria or missing video | Playwright, video forced on (`factory/e2e/playwright.config.mjs`); specs in repo `e2e/` (agent-authored) |
| `round-video.sh` | iterate-lane round walkthrough video; never blocks the loop | same runner; `e2e/tour.spec.*` or generic tour; artifacts in `factory-artifacts/<run>/round-N/` |
| `open-pr.sh` | PR with artifacts | `FACTORY_BASE_BRANCH` |
| `merge.sh` | wait checks, squash-merge | — |
| `prod-e2e-video.sh` | e2e vs prod, video forced on | `FACTORY_PROD_URL`; same Playwright runner |

## Running

```bash
fabro validate factory/workflows/<lane>.dot   # lint a graph
fabro run express-lane     --goal "move the Save button to the left of Cancel"
fabro run iterate-lane     --goal "rough cut of the runs filter panel"
fabro run feature-pipeline --goal "…feature description…"
fabro run feature-quick    --goal "…feature description…"   # no spec, questions only
fabro run bugfix-express   --goal "artifacts 404 when run id contains a dot"
fabro run bugfix-deep      --goal "runs intermittently stuck in Verify"
fabro attach <run-id>                         # watch / answer gates
```

Source graphs live in `factory/workflows/*.dot`; runnable copies in
`.fabro/workflows/<name>/`. After editing a source graph, re-sync:
`cp factory/workflows/<name>.dot .fabro/workflows/<name>/workflow.fabro`.

Gates can be answered in the CLI, the web UI (http://127.0.0.1:32276), or via
`fabro approve`.

## Current setup state

- LLM: anthropic provider routed through the `claude.eventyr.cloud` proxy —
  `base_url` in `~/.fabro/settings.toml`, token in the fabro vault
  (`fabro secret set ANTHROPIC_API_KEY …`). **Blocked on the gateway side**:
  the consumer token must be bound to an account in the eventyr admin.
  Verify after binding: `fabro model test --model claude-haiku-4-5`.
- Sandbox: `provider = "local"`; Docker sandbox disabled in settings.
  For isolation later: start Docker Desktop and re-enable, or
  `fabro secret set DAYTONA_API_KEY` for cloud sandboxes.
- GitHub: token strategy, wired to `notdetninja47/product-planner`.

## Remaining setup (operator)

1. Bind the `cag_…` consumer to an account at claude.eventyr.cloud.
2. **Coolify previews**: set `COOLIFY_URL`, `COOLIFY_TOKEN`, `COOLIFY_APP_UUID`,
   `PREVIEW_DOMAIN` (wildcard DNS) per product.
