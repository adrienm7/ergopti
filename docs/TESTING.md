# Running the tests (and fixing a CI failure)

This is the single source of truth for running ErgoptiPlus's tests **locally,
exactly as CI runs them**. When a CI check goes red, find its layer below and run
the one command — the local output is byte-identical to CI.

The test suite spans four independent layers. CI runs them as separate jobs; you
only need the layer whose check failed.

| Layer                       | One command                   | CI job                                         | Needs         |
| --------------------------- | ----------------------------- | ---------------------------------------------- | ------------- |
| **JS / domain / codegen**   | `npm run test:js`             | `YAML, shared code & web / Unit tests (<lot>)` | Node 22       |
| **Windows (AHK)**           | see [§ Windows](#windows-ahk) | `Windows / Unit tests (<category>)`            | AutoHotkey v2 |
| **macOS (Hammerspoon/Lua)** | `npm run test:hs`             | `macOS / Unit tests (<lot>)`                   | Lua 5.4       |
| **Linux (Lua)**             | `npm run test:linux`          | `Linux / Unit tests (<group>)`                 | LuaJIT        |

`Validate and plan` is the root job of [`ci.yml`](../.github/workflows/ci.yml):
it validates the release inputs and resolves the plan. The `Core` matrix then
runs in parallel with the three OS lanes. A check named
`<OS> / <stage> (<what it tests>)` is a job of the workflow that `ci.yml`
calls for that OS:
[`ci-windows.yml`](../.github/workflows/ci-windows.yml),
[`ci-macos.yml`](../.github/workflows/ci-macos.yml) or
[`ci-linux.yml`](../.github/workflows/ci-linux.yml). Each draws one lane,
`Unit tests → Integration tests → E2E tests → Build → Install and launch → Verdict`,
with one job per stage. A matrix stage keeps its static name and GitHub appends the row, so
its rows read `Linux / Unit tests (core)` and its graph group
`Matrix: Linux / Unit tests`; a single job names its subject in parentheses.
Variants are grouped into one installation matrix per OS.
`macOS / Build (ErgoptiPlus.app, macOS 26)` also builds the Swift launcher
and runs its XCTest
(`swift test --package-path static/ergopti_plus/macos/launcher`, macOS only)
before it builds the app.

The three test stages split by what a test exercises, the same way on every
row:

- **Unit tests** check one module or one source contract, with its neighbours
  stubbed.
- **Integration tests** run several real modules together, or real files,
  processes, generators, packaging scripts or the driver's own startup. They
  start only when every Unit row passed.
- **E2E tests** drive the driver the way a user does (corpus replay, virtual
  keyboard, native sessions). They start only when Integration passed.

| Row                     | Integration job                                     | What it runs                                                                                                                                                              |
| ----------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| YAML, shared code & web | `Integration tests (Generators and parity)`         | the `integration-generators-and-parity` feature lot: the generators run and every committed `_generated/` file matches them; the drivers resolve the same manifest values |
|                         | `Integration tests (Packaging and boot)`            | the `integration-packaging-and-boot` feature lot: the Linux installer and uninstaller in a sandbox, the bundle payloads of every OS and two isolated AHK boot smokes      |
| Windows                 | `Integration tests (Driver startup)`                | `node tools/test/test-ahk-full-startup-smoke.cjs`: the whole driver boots                                                                                                 |
|                         | `Integration tests (Fresh clone bootstrap)`         | `node tools/test/test-ahk-fresh-clone-startup.cjs`: a fresh Git clone bootstraps, then starts warm                                                                        |
|                         | `Integration tests (Native cohorts and contracts)`  | the native desktop AHK cohorts, the Kana layout install, the manifest parity check and the managed Ollama file component                                                  |
| macOS                   | `Integration tests (Lua module wiring, stubbed hs)` | `lua tests/run.lua --module=integration`: the files the `integration` group of `tests/support/module_groups.lua` names                                                    |
| Linux                   | `Integration tests (driver)`                        | `luajit tests/run.lua --module=integration`: the files the `integration` group of `tests/support/module_groups.lua` names                                                 |
|                         | `Integration tests (native)`                        | the metrics aggregation and histogram equivalence against Python, the XI2 LuaJIT ABI qualification and the manual managed Ollama runtime acceptance                       |

A test moves between Unit and Integration through its owner only: a feature
lot's `suite.json` folder (the `integration-` prefix marks an Integration
lot) for the shared row, the `integration` group of each Lua driver's
`module_groups.lua`, and the lot conditions of `ci-windows.yml`. Selecting
the Lua `integration` group fails when a file it names is not discovered, so
a rename cannot silently drop a test.

---

## JS / domain / codegen

```bash
npm run test:js            # the everyday gate — the CI "Unit tests" lots of the shared lane
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
`test:properties` (fast-check) and `test:mutation` (Stryker). CI exposes them as
`YAML, shared code & web / Unit tests (Property tests)` and
`… (Mutation tests)`, with mutation on `main` only. These lots run independently
of the `test:js` feature lots; the release waits for all of them.

**Not bundled at all**: `python tools/format_toml.py --hotstrings --all --check`
(hotstring TOML sorting/formatting) is its own lot,
`YAML, shared code & web / Unit tests (Hotstring TOML formatting)`.
Run it after touching any hotstring `.toml`.

**Adding a feature flag?** Edit only `static/ergopti_plus/_shared/modules/features/manifest.toml`,
then `npm run codegen`, then commit the regenerated `_generated/` files. If you
read it in AHK as `Features["<section>"]["<id>"]`,
`test:feature-read-sites` proves the path is backed by the manifest — a mismatch
(the `ctrl_magic_save` crash class) fails here, not at the user's keyboard.

---

## Windows (AHK)

AHK is a GUI runtime. `/ErrorStdOut` routes runtime errors to stderr; it does
not prevent a script from activating a window or injecting input. The unit
runner excludes tests registered with `Test(Name, Callback, true)` unless
`--interactive` is explicitly supplied. Excluded cases are listed in TAP
comments and do not count as executed or passed. `--only` does not override
this admission rule. The runner calls `ExitApp` when execution finishes.

Run the suite on the interpreter the release exe ships, named by
`static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json`
(`runtime.version`): the hook's prefix-key and key-up rules differ between
AutoHotkey releases, and a runtime-contract case fails on any other version.

```bash
AHK="C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe"  # the contract runtime (2.0.26)
RUN="static/ergopti_plus/windows/tests/run_all.ahk"

# Parse/load gate only (fast — proves the whole #Include graph parses):
"$AHK" /ErrorStdOut "$RUN" --dry-run

# Full unit suite:
"$AHK" /ErrorStdOut "$RUN"

# Desktop-affecting cases: run only on an explicitly authorized idle desktop.
"$AHK" /ErrorStdOut "$RUN" --interactive --only keepawake-visible-cancellation

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
lua tests/run.lua --module=integration  # only the Integration stage's files
lua tests/e2e/run_e2e.lua         # E2E virtual-keyboard harness
```

Tests run against stubs, so no real Hammerspoon install is needed. Output ends
with an OVERALL RESULTS block; a non-zero "Failed tests" count is the failure.

---

## Linux (Lua)

```bash
cd static/ergopti_plus/linux
luajit tests/run.lua
luajit tests/run.lua --module=integration  # only the Integration stage's files
```

---

## Regression-test discipline

Per the delivery contract in [AGENTS.md](../AGENTS.md), **every bug fix ships a
regression test in the same commit**, in the suite for the affected layer (`windows/tests`,
`macos/tests`, or `tools/test`). Encode the root cause, not just the symptom, so
the bug can never silently return.
