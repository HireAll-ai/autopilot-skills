---
author: agent
issue: AS-26
date: 2026-10-28
---

# /autoship rebases only on a conflict or a moved contract

From plugin 3.3.0, `/autoship` merges a branch that is behind its base but mergeable as it is, when
the base isn't strict (`.git.protection.strict` false). It doesn't rebase, force-push or
`gh pr update-branch` it. It still rebases in four cases: GitHub reports the PR `CONFLICTING` /
`DIRTY`, a contract the diff depends on moved on the base, the PR is stacked and its base PR merged,
or the base is strict. A stuck review score gets one re-review of the same head instead of a rebase.
`/autodev` follows the same rule before its draft PR. Every push restarts CI and the auto-reviewer:
on ai-backlog that was 138 force-pushes for 147 PRs in five days. Details are in
[When /autoship and /autodev rebase](../rebasing.md).
