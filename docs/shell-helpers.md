# Shell helpers: config values and portability

How the plugin's bash helpers in `autopilot/lib/` read values out of `.claude/autopilot.config.json`
safely, and what makes the same script behave differently from one machine to the next.

## Where a value is checked

- `autopilot-config.sh get <filter> [default]` returns a value as `jq -r` prints it, with no check
  of its own. A config that is missing, unreadable or not one JSON object fails `get` with rc 2.
- A value that a script feeds to bash arithmetic gets a checker of its own in `autopilot-config.sh`.
  `validate` runs that checker too, so a value that would fail after a merge already fails at config
  time. Today there is one: `autopilot-config.sh timeout [file]` for `.deploy.verify.timeoutSeconds`.
  - Absent or `null` gives 600.
  - It accepts a whole number from 0 to 86400, either as a JSON number (`30`, `30.0`, `1e3`) or as
    a string of ASCII digits (`"030"` is 30, not octal).
  - It prints only the seconds. Anything else gives rc 2 with the message
    `.deploy.verify.timeoutSeconds must be a whole number of seconds from 0 to 86400, got '<value>'`.
  - `verify-deploy.sh` reads the timeout through this checker, never through `get`.
- With ajv installed, `validate` checks the full schema, which takes only JSON integers (no digit
  strings). Without ajv, its jq fallback checks the required keys, the `version` and the checkers
  above. The fallback is the usual path.

## Why values are checked by type in jq, not as text in bash

- **jq versions print numbers differently.** jq 1.6 prints `99999999999999999999` as `1e+20` and
  `30.0` as `30`. jq 1.7 prints both as written. A check on `jq -r` output therefore gives different
  results on different machines.
- **bash's `[0-9]` depends on the locale.** Under glibc's `en_US.UTF-8` it also matches Arabic-Indic
  digits (`٣٠`). A digit check in bash has to spell out `0123456789`.
- **bash arithmetic evaluates strings.** `$(( x + 0 ))` reads `abc` as a variable name. A value like
  `PATH[$(cmd)]` runs `cmd`. Past 64 bits, the number wraps silently.
- **A child bash can write to stderr when it succeeds.** When `LC_ALL` names a locale the system
  lacks, which is common in containers, glibc's bash prints a `setlocale` warning at every start.
  Capture only a helper's stdout for a value (`"$(helper 2>/dev/null)"`). Read its stderr separately,
  and only when it fails, as `verify-deploy.sh` does.

## Pitfalls when testing

- CI (`.github/workflows/check.yml`) runs the tests on Ubuntu and on macOS. Both runners have jq
  1.7 or later, which prints numbers as written. macOS repeats the tests under `/bin/bash` 3.2. A
  local jq may be 1.6, so a test that checks a number in a message should accept both renderings
  (see `autopilot/test/verify-deploy.sh`, `1e\+20`).
- Write a literal number that jq would rewrite (`30.0`, `99999999999999999999`) as a placeholder
  string, then `sed` it into the file. Passing it through `jq --argjson` changes it.
- Locale-dependent cases run under the first of `en_US.UTF-8` or `C.UTF-8` that `locale -a` lists,
  and are skipped when neither is there.
