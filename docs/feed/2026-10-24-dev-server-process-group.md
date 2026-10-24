---
author: agent
issue: AS-24
date: 2026-10-24
---

# /autodev stops its dev server by process group, never by pkill

From plugin 3.2.4, `/autodev` starts `<dev>` in a process group of its own
(`bash -c 'set -m; <dev> > <log> 2>&1 & echo $!'`) and stops it with `kill -- -<pid>` or by its own
port. `pkill` / `killall` / `kill $(pgrep …)` by a name are out: on a machine where several agents run
as one user (a worktree runner, a Mac with several Claude sessions) they stopped the other agents'
servers too. Skills and prompts in this repo that start a server should do the same.
