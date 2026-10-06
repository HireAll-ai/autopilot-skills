# Scenario browser e2e (`--e2e`) — shared by /autodev Step 4.5 and /autoship Step 5.6

Read this only when `--e2e` was passed. It walks **these exact user flows** end-to-end — deterministic
happy-path verification, unlike the heuristic bug-hunt of a QA pass. Two modes:

| | **local** (`/autodev` 4.5) | **deployed** (`/autoship` 5.6) |
|---|---|---|
| target | the already-warm local dev server | the deploy URL |
| failures | fix-loop: fix the code, re-run | **report-only** — code is merged; fixes are follow-up PRs |
| blocks | the "tested" claim in the handoff | the ticket move (Step 6) |

`<plugin root>` below is the directory above this `lib/`. Config values (`.qa.*`) come from the config
already in context — substitute them literally.

## 1. Derive scenarios

From the diff + the `<KEY>` ticket + the feature intent (deployed mode: + the PR body), write **2–4 key
user flows**: the happy path plus the critical branches this change introduces (submit → success,
invalid input → error, the cross-cutting API→UI→DB effect). Record them explicitly.

## 2. Run

**`.qa.video.enabled` is true** → drive each scenario with the recorder so the run is captured to
video. Write the scenario as JSON (steps: `goto`/`fill`/`click`/`press`/`waitFor`/`expect`/
`screenshot`/`wait` — see the recorder header) and run:

```bash
node "<plugin root>/lib/record-e2e.mjs" <scenario>.json \
  --out-dir "<.qa.video.dir, default .context/video>" \
  --format  "<.qa.video.format, default mp4>" \
  --base-url "<local dev url | deploy url>" --max-seconds "<.qa.video.maxSeconds, default 90>" \
  [--gif]   # add when .qa.video.surface is pr-gif or both
```

| exit | meaning | do |
|---|---|---|
| 0 | all steps passed | ✓ |
| 1 | a step failed (video still saved) | use the video to debug → §3 |
| 2 | Playwright unavailable | run this scenario with `.qa.browseSkill` **without** video — a missing recorder never blocks the e2e |
| 3 | scenario/usage error (bad flags, malformed JSON) | **fix the scenario and re-run** — do NOT fall back, do NOT mark it green |

**Video off** → drive each scenario step-by-step with **`.qa.browseSkill`** (`/browse`): navigate →
fill → click → assert state / screenshot.

Non-UI flows: assert the end effect (DB row / API response), not the page.

## 3. Failures

- **local** — fix-loop (this is the "tested" guarantee): find the cause, fix the code (`<KEY>:`
  commit), `<typecheck>`, re-run that scenario. **Max 3 attempts** per scenario. Still failing → do
  **NOT** present the feature as green; carry the red e2e into the Step 5 handoff as a blocker.
- **deployed** — a scenario failing **because of this ship** → **blocks Step 6**; report the failing
  step + screenshot/video and offer revert or fix-forward. Pre-existing breakage → include, don't block.

## 4. Report + surface the video

Write the scenarios + per-step result + artifact paths (screenshots **and video**) to
`.context/e2e-<KEY>.md` (deployed mode: `.context/e2e-<KEY>-deployed.md`); it feeds the PR body and the
final handoff/report. Per `.qa.video.surface`:

- `context` / `both` → the mp4 (or webm) is already under `.context/` (gitignored — right for chat):
  reference it in the handoff so it renders in the Conductor chat (prefer the gif for a guaranteed
  inline preview).
- `pr-gif` / `both` → include the **gif** in the PR body (or a PR comment, deployed mode). GitHub only
  renders drag-dropped video, so an API-authored body can't embed fresh video. Because `.context/` is
  gitignored, first copy the gif to a **committed** path (e.g. `docs/qa-media/<KEY>/<name>.gif`),
  commit it, and reference its raw URL (`https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`);
  link the mp4/webm path for full quality.
- `none` → keep the artifact paths in the report only.
