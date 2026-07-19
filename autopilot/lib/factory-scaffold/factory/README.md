# Software Factory

Autonomous spec-to-deploy pipeline with human gates, orchestrated by
[fabro](https://github.com/fabro-sh/fabro). Claude Code + gstack act as
executors inside stages; Coolify/DO provide preview and prod deploys.

> First time in a repo? Run `/autopilot:init` (checks gstack, scaffolds the
> factory, bootstraps DESIGN.md and baseline docs) before dispatching runs.

## Lanes — which workflow for which task

Five lanes, one shared ship path (tests → docs → PR → review → merge → prod
video → canary). They differ in what plays the role of the spec and in how
much operator attention they consume:

| Lane | Task type | "Spec" is… | Human gates | Preview | Review |
|---|---|---|---|---|---|
| `express-lane` | dictated tweak: move/hide a button, copy change | the goal sentence itself | **0** | — | — (tests only) |
| `iterate-lane` | "know it when I see it": UX, layout, product feel | the feedback loop (+ design variants, taste memory) | N × Feedback / Done | every round + walkthrough video | full + QA + CSO, after Done |
| `feature-pipeline` | big feature, long autonomous block (30 min+) | `spec.md` + `design.html` — or questions only with `-I no_spec=true` | 2 (spec, accept) — Gate 1 auto-resolvable with `-I auto=true` | once, with e2e video + QA report | full + CSO |
| `bugfix-express` | bug with obvious cause + repro | the failing repro test | **0** | — | — (tests only) |
| `bugfix-deep` | unclear cause, wide blast radius, incidents | `rootcause.md` (evidence chain) | 2 (diagnosis, accept) | once, e2e of broken flow | full, regression-focused |

**Choosing (30-second rules):**

1. Can you dictate the change in one message, and a wrong result costs only
   another run (no data/auth/payments touched)? → `express-lane`.
2. You'll only know it's right when you click it? → `iterate-lane`.
3. New capability with decisions that are expensive to undo (data model,
   APIs, integrations), or hours of autonomous work? → `feature-pipeline`.
   Don't want a spec document — just answer a short list of implementation
   questions? → add `-I no_spec=true`. Don't want to read the spec at all? →
   add `-I auto=true` (see Modes below).
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
spec/clarify ──▶ plan review ──▶ [Gate 1: Approve — skipped when auto-approved]
                                     │
        implement ──▶ tests ──▶ (fix loop) ──▶ preview deploy
                                     │
        e2e + video ──▶ exploratory QA (report-only)
                                     │
                     [Gate 2: Accept / Steer / Rework]
                                     │
        docs update ──▶ PR ──▶ cross-review ──▶ security review (CSO)
                                     │
        fixes ──▶ merge ──▶ prod e2e + video ──▶ canary ──▶ summary
```

- **Gate 1** — approve the spec (or the implementation questions in no-spec
  mode); the digest at the gate lists every open decision with a
  recommendation. `[A] Approve` / `[C] Approve with corrections` proceed,
  `[R] Revise` loops back with your freeform feedback.
- **Gate 2** — accept the feature after watching the e2e video, reading the
  QA digest, and clicking through the preview deploy. `[S] Steer` sends
  freeform notes back to the implementing agent; `[R] Rework Spec` restarts
  from the spec. **Gate 2 is always human, in every mode.**

### Modes (workflow inputs, `-I key=true`)

- **`-I no_spec=true`** — absorbs the old `feature-quick` lane: stage 1 writes
  `questions.md` (the 2-6 implementation decisions with recommendations)
  instead of `spec.md`/`design.html`. The contract is the goal + the answers.
- **`-I auto=true`** — autoplan mode: an independent plan reviewer (fresh
  context, gstack autoplan principles) resolves every auto-decidable open
  decision into `decisions.md` and Gate 1 is skipped (`AUTO_APPROVED`).
  Decisions it may **never** make alone — data models/migrations, auth,
  payments/pricing, externally visible APIs/naming, product premises, pure
  taste — force the gate open (`NEEDS_OPERATOR`) with only those decisions in
  the digest. Cost of a wrong auto-call is one wasted run: Gate 2 still
  catches direction errors.
- The flags **compose**: `-I no_spec=true -I auto=true` = the reviewer answers
  the implementation questions by the principles, escalating only
  operator-only ones. This is the thinnest contract — prefer plain
  `-I auto=true` (spec exists, reviewer resolves it) when the feature touches
  anything structural.

## Other lanes (structure deltas vs feature-pipeline)

- **`express-lane`** — implement → scope check → tests → PR → merge →
  prod smoke video → canary → summary. No spec, no gates, no cross-review; the
  agent is prompted to be conservative (smallest diff, no refactoring) because
  nothing human stands before merge. Failure mode is fix-forward; the canary
  is the safety net after it.
- **`iterate-lane`** — increment → suite green → preview → walkthrough video
  of the round (`round-video.sh`, non-blocking demo artifact:
  `factory-artifacts/<run>/round-N/`) → `[D] Done / [F] Feedback` gate looping
  back into one shared thread (context accumulates across rounds,
  `max_visits=20`). **Design rounds** (gstack design-shotgun style): on
  unsettled visual work the agent also generates 3-4 static design variants
  next to the preview, and operator taste feedback accumulates in
  `factory/design-taste.md` — honored in every later round and run. Tests are
  written once, after Done; then a fresh preview redeploy → exploratory QA
  (bug-fix loop, behavior frozen) → docs update → PR → review (also hunts dead
  ends left by abandoned rounds) + security review → merge → prod e2e →
  canary.
- **`bugfix-express`** — reproduce (failing test first, commit it) → fix →
  tests → PR → merge → prod smoke → canary. Repro and fix share a thread.
  Cannot reproduce / cause non-obvious ⇒ ESCALATE to `bugfix-deep`.
- **`bugfix-deep`** — investigate (evidence chain, blast radius, fix options
  in `rootcause.md`) → Gate 1 approves the *diagnosis and plan* → fix +
  regression tests across the blast radius → preview e2e video of the broken
  flow → Gate 2 → docs correction (stale docs the root cause exposed +
  CHANGELOG) → PR → review (hunts regressions and symptom-patching) → merge →
  prod e2e → canary → post-mortem instead of a plain summary.

## Ship-path invariant

The ship path (docs → PR → review[s] → merge → prod video → canary → summary)
is intentionally duplicated in every lane graph — fabro has no includes.
Prompts may differ per lane (review focus etc.); **structure may not**. After
editing any lane, run both:

```bash
fabro validate factory/workflows/<lane>.dot
./factory/workflows/lint-ship-path.sh   # structural drift check across lanes
```

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
| `canary.sh` | post-merge prod watch: polls prod, fails on consecutive errors | `FACTORY_CANARY_MINUTES/INTERVAL/PATH/MAX_CONSECUTIVE_FAILURES/SLOW_SECONDS`; report in `factory-artifacts/<run>/canary/` |

## Running

```bash
fabro validate factory/workflows/<lane>.dot   # lint a graph
fabro run express-lane     --goal "move the Save button to the left of Cancel"
fabro run iterate-lane     --goal "rough cut of the runs filter panel"
fabro run feature-pipeline --goal "…feature description…"
fabro run feature-pipeline --goal "…" -I no_spec=true      # questions instead of a spec
fabro run feature-pipeline --goal "…" -I auto=true         # autoplan: Gate 1 only if needed
fabro run bugfix-express   --goal "artifacts 404 when run id contains a dot"
fabro run bugfix-deep      --goal "runs intermittently stuck in Verify"
fabro attach <run-id>                         # watch / answer gates
```

> Migration note: the old `feature-quick` lane was merged into
> `feature-pipeline` as `-I no_spec=true` (same questions-gate behavior, same
> ship path). Its graph and `.fabro/workflows/feature-quick/` are gone.

Source graphs live in `factory/workflows/*.dot`; runnable copies in
`.fabro/workflows/<name>/`. After editing a source graph, re-sync:
`cp factory/workflows/<name>.dot .fabro/workflows/<name>/workflow.fabro`.

Gates can be answered in the CLI, the web UI (http://127.0.0.1:32276), or via
`fabro approve`.

## Setup (per product)

- LLM: `fabro install` (anthropic direct or a compatible proxy via
  `ANTHROPIC_BASE_URL`); token in the fabro vault
  (`fabro secret set ANTHROPIC_API_KEY ...`).
- Sandbox: `provider = "local"` to start; Docker/Daytona later for isolation.
- GitHub: token strategy wired to the product repo.
- **Coolify previews**: set `COOLIFY_URL`, `COOLIFY_TOKEN`, `COOLIFY_APP_UUID`,
  `PREVIEW_DOMAIN` (wildcard DNS) in `factory/config.env`.
- Point `FACTORY_PROD_URL` at the real prod URL once deployed (the canary
  watches it after every merge).
