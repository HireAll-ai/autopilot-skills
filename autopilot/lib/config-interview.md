# First-run config interview (shared by /autopilot:init, /autodev, /autoship, /autopilot)

Read this only when the config loader exited **3** — no `.claude/autopilot.config.json` yet, or
`--reconfigure` was passed. Its stdout is an **autodetected draft**: package-manager commands, base
branch + protection, ticket prefix, commit style, health URL, and a deploy workflow when one is found.

1. **Start from what exists.** With `--reconfigure`, Read the current
   `.claude/autopilot.config.json` and treat its values as the defaults; the draft only refreshes
   what can be autodetected. Without a config, the draft is the starting point.
2. **Confirm in one compact message, not one question per field.** Show the detected values and fill
   the gaps the detector can't know. Prefer `AskUserQuestion` for the choices:
   - `tracker.type` / `tracker.mcp` / `tracker.shipStatus` (+ `shipStatusVia` when the board gates it);
     `tracker.autoCreateIssue` — may `/autodev` open a missing ticket itself? Default `false` (it asks);
     check the repo's rule docs first, many reserve that for a human;
   - `git.commitStyle` — `key-prefix` (`<KEY>: …`) or `conventional` (`type(scope): …`); the draft
     guesses from recent subjects, the repo's docs or commit linter settle it — and `git.branchPattern`:
     `{key}` / `{key_lower}` / `{slug}` (e.g. `{key_lower}-{slug}` → `pos-42-add-filter`);
   - `review.gate` + `review.skill` + `review.passBar` (+ `review.localReviewers`);
   - `deploy.urls`, and **how a deploy is proven**: `deploy.verify.mode` — `build-id` (an endpoint
     that names the running commit: `buildIdUrl` + `buildIdJq`), `github-run` (the deploy *is* a
     GitHub Actions run: set `workflow` to its name/file, else every push run must go green), or
     `none` (reported as UNVERIFIED);
   - `git.mergeQueue` if the base branch merges through a merge queue;
   - `qa.preview.authPath` (dev-only sign-in route) and whether to enable `qa.video`.
3. **Write** the completed JSON to `.claude/autopilot.config.json` (drop the draft's `_note`),
   `git add` it, and validate: `<plugin root>/lib/autopilot-config.sh validate`. It is committed and
   reused by the whole team, so this is a one-time cost per repo.
4. Continue with the command that sent you here — the config you just wrote is the one it uses.
