# When /autoship and /autodev rebase

When the autopilot commands rebase a PR branch on its base, and why they don't do it just because the
base moved. The rule lives in `autopilot/commands/autoship.md` (the line under the intro, Steps 0.5,
2.3 and 3) and in the Draft PR paragraph of `autopilot/commands/autodev.md`.

## The rule

Base not strict → being behind is fine; every push restarts CI and the auto-reviewer; rebase only on
a conflict or a moved contract.

`/autoship` Step 0.5 rebases a branch that is behind its base only when one of these holds:

- `.git.protection.strict` is true. A strict base can't merge a behind branch.
- GitHub reports a conflict: `gh pr view --json mergeable,mergeStateStatus` gives `CONFLICTING` or
  `DIRTY`.
- A contract moved. The semantic-overlap check (`git diff --name-only "HEAD...origin/<base>"`) shows
  that shared surface this diff depends on changed on the base: `packages/*`, DB migrations or
  entities, an API contract, `package.json` or a lockfile.
- The PR is stacked and its base PR merged in this run. It rebases with `--onto`, as before.
- The PR doesn't exist yet. Nothing has run on the branch, so a rebase restarts nothing.

Otherwise the branch is pushed as a plain fast-forward (a no-op when nothing new was committed) and
merged as it is. No rebase, no force-push, no `gh pr update-branch`, which is a sync by another name.

Step 3 asks GitHub again just before the merge. `CONFLICTING` / `DIRTY`, or `BEHIND` on a strict
base, rebases and re-runs the whole review loop. A plain `BEHIND` on a non-strict base doesn't. The
semantic-overlap check runs once more on what moved meanwhile.

A review score stuck below `.review.passBar` with every thread resolved gets one re-review of the
same head (`.review.mention`, else the review skill's own trigger), never a rebase. If it is still
stuck, the run stops and reports.

`/autodev` doesn't rebase before or after opening its draft PR unless the PR conflicts or a contract
moved. A strict base is left to `/autoship`, which syncs it just before its merge.

## Why

Every rebase is a force-push. It re-runs CI and starts a fresh auto-review round, and that round often
finds something new and turns a green PR red. With 6–8 agents shipping into one repo, the base moves
every few minutes. HireAll-ai/ai-backlog (`strict` false) merged 147 PRs on Oct 23–28, 2026. They took
138 force-pushes, and 49% of the PRs got at least one. That cost about 25 h of CI and at least 72 extra
Greptile rounds. PRs that overlapped a merge got 2.5–10× more pushes than PRs of the same size that
didn't. On the days the agents were told to merge on green + CLEAN and rebase only on a conflict,
pushes per PR fell from 1.17 to 0.2–0.5.

## Pitfalls

- `mergeable` is `UNKNOWN` until GitHub has computed it, often on the first query after the base
  moved. Step 0.5 doesn't rebase on a guess, because Step 3 asks again. If it is still `UNKNOWN` at
  Step 3, the merge goes ahead: GitHub refuses to merge a conflicting PR, and that refusal takes the
  conflict path.
- GitHub runs no `pull_request` workflows on a PR with a merge conflict. A conflicting draft has no
  pre-warmed CI to keep, so `/autodev` rebases it.
- A PR whose checks went green before the base moved keeps those checks. They are the checks of its
  head commit, and moving the base doesn't re-run them.

## Tests

`autopilot/test/stacked-merge.sh` runs these steps against a local bare repo. Its `gh` stub
(`autopilot/test/bin/gh`) works out `mergeable` / `mergeStateStatus` with a test merge in a scratch
clone. The scenarios cover four cases:

- `behind-mergeable`: the PR merges with its head unchanged.
- `behind-conflicting`: the PR is rebased, the conflict is resolved, and then it merges.
- `behind-strict`: the PR is rebased.
- `behind-contract`: `package.json` moved on main, and the PR is rebased.

The step functions in the script repeat the command's steps with the placeholders filled in, so
change them together with `autoship.md`.
