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
to reproduce that one check** plus the tail of its output. It bundles:

- `npm run build:domain` — the codegen pipeline + drift detection. This is the
  one that catches "I edited the manifest but forgot to regenerate". It runs, in
  order: `build:manifest`, `codegen:*`, `test:manifest-parity`,
  `test:port-compliance`, `test:config-schema`, `test:feature-read-sites`, then a
  **drift-check** (`git diff` over every generated file). If drift-check fails,
  run `npm run codegen` and commit the regenerated files.
- `test:priority-parity`, `audit-translations`, `lint:conventions:strict`.

Not in `test:js` (run on demand): `python tools/format_toml.py --hotstrings
--all --check` (hotstring TOML formatting), `npm run test:properties`,
`npm run test:mutation`.

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

Per [CLAUDE.md](../CLAUDE.md) §5.9, **every bug fix ships a regression test in the
same commit**, in the suite for the affected layer (`windows/tests`,
`macos/tests`, or `tools/test`). Encode the root cause, not just the symptom, so
the bug can never silently return.
