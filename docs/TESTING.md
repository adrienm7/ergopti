# Running the tests (and fixing a CI failure)

This is the single source of truth for running ErgoptiPlus's tests **locally,
exactly as CI runs them**. When a CI check goes red, find its layer below and run
the one command — the local output is byte-identical to CI.

The test suite spans four independent layers. CI runs them as separate jobs; you
only need the layer whose check failed.

| Layer | One command | CI job | Needs |
|---|---|---|---|
| **JS / domain / codegen** | `npm run test:js` | `Validate · …` | Node 22 |
| **Windows (AHK)** | see [§ Windows](#windows-ahk) | `Windows · unit tests` | AutoHotkey v2 |
| **macOS (Hammerspoon/Lua)** | `npm run test:hs` | `macOS · unit tests` | Lua 5.4 |
| **Linux (Lua)** | `npm run test:linux` | `Linux · unit tests` | LuaJIT |

---

## JS / domain / codegen

```bash
npm run test:js            # the everyday gate — mirrors the CI "Validate ·" jobs
npm run test:js -- --full  # also runs the slow property + mutation tests
```

`test:js` prints a pass/fail line per check and, on failure, the **exact command
to reproduce that one check** plus the tail of its output.

**The inventory of checks is the run itself.** `run-js-suite.cjs` prints one
bullet per check as it goes, so `npm run test:js` on your own tree is the
authoritative list — and the `CHECKS` array in `tools/test/run-js-suite.cjs` is
its single source of truth. It carries drift detection, cross-driver parity,
single-source ratchets, bridge wiring, encoding and syntax gates, and new ones
land regularly; re-typing them here would be stale within a week, so this page
deliberately does not — including their count, which the run prints. Same rule one level down: `build:domain` names
each of its own steps as it runs them.

Two entries are worth explaining, because the name does not tell you what a
failure means:

- **`domain pipeline (…)`** = `npm run build:domain`, the codegen pipeline plus
  drift detection. This is the one that catches "I edited the manifest but forgot
  to regenerate": it rebuilds every generated file, runs the parity/schema/port
  checks over the result, then **drift-checks** (`git diff`) the generated tree.
  If the drift-check fails, run `npm run codegen` and commit the regenerated
  files — the code is fine, the commit is incomplete.
- **`tests that cannot fail (…)`** = `tools/test/find-false-greens.cjs`, a
  ratchet on tests that can never go red (tautologies, vacuous absence
  assertions, unregistered tests, `pcall`-only bodies). It only turns down, so a
  failure means a new false green was added, not that a test broke.

**Slow checks**, excluded from the default run: `npm run test:js -- --full` adds
`test:properties` (fast-check) and `test:mutation` (Stryker). CI runs both in the
`Validate · JS ports + properties` job, mutation on `main` only.

**Not bundled at all**: `python tools/format_toml.py --hotstrings --all --check`
(hotstring TOML sorting/formatting) is its own CI job, `Validate · hotstrings
TOML`. Run it after touching any hotstring `.toml`.

**Adding a feature flag?** Edit only `static/ergopti_plus/_shared/modules/features/manifest.toml`,
then `npm run codegen`, then commit the regenerated `_generated/` files. If you
read it in AHK as `Features["<section>"]["<id>"]`,
`test:feature-read-sites` proves the path is backed by the manifest — a mismatch
(the `ctrl_magic_save` crash class) fails here, not at the user's keyboard.

---

## Windows (AHK)

AHK is a GUI runtime; the suite is launched headless via `/ErrorStdOut` and the
runner calls `ExitApp`, so it terminates.

```bash
AHK="C:/Program Files/AutoHotkey/v2.0.19/AutoHotkey64.exe"
RUN="static/ergopti_plus/windows/tests/run_all.ahk"

# Parse/load gate only (fast — proves the whole #Include graph parses):
"$AHK" /ErrorStdOut "$RUN" --dry-run

# Full unit suite:
"$AHK" /ErrorStdOut "$RUN"

# E2E:
"$AHK" /ErrorStdOut "static/ergopti_plus/windows/tests/e2e/run_e2e.ahk"
```

- A **parse error** (missing function, bad `#Include`, encoding drift) is printed
  to stderr by `/ErrorStdOut` instead of popping a modal — use `--dry-run` first.
- Output is TAP (`1..N`, `ok`/`not ok`). Search the output for `not ok` to find
  the failing assertion.
- **Encoding rule:** all repository text uses LF. `.ahk` files additionally require
  a UTF-8 BOM. Always run `npm run test:ahk-encoding` after editing any `.ahk`.

---

## macOS (Hammerspoon / Lua)

```bash
cd static/ergopti_plus/macos
lua tests/run.lua                 # unit + meta tests (auto-discovered)
lua tests/e2e/run_e2e.lua         # E2E virtual-keyboard harness
```

Tests run against stubs, so no real Hammerspoon install is needed. Output ends
with an OVERALL RESULTS block; a non-zero "Failed tests" count is the failure.

---

## Linux (Lua)

```bash
cd static/ergopti_plus/linux
luajit tests/run.lua
```

---

## Regression-test discipline

Per the delivery contract in [AGENTS.md](../AGENTS.md), **every bug fix ships a
regression test in the same commit**, in the suite for the affected layer (`windows/tests`,
`macos/tests`, or `tools/test`). Encode the root cause, not just the symptom, so
the bug can never silently return.
