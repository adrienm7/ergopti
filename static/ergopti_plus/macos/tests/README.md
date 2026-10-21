# Hammerspoon Driver — Test Suite

Comprehensive Lua unit, meta, and integration tests for the code under
`static/ergopti_plus/macos/`. The suite is **runnable on Linux, macOS and
Windows** under plain Lua 5.4 — no external dependencies required.

## Layout

The tree mirrors the driver source: a test of `modules/keymap/…` lives in
`tests/unit/modules/keymap/<stage>/`, a test of `ui/menu/…` in
`tests/unit/ui/menu/<submenu>/`.

```
tests/
├── run.lua              Runner entry point (zero-dep): --only, --module
├── helpers/             Shared assertions, mini test runner, pbt.lua
├── stubs/hs.lua         Hammerspoon API shim
├── support/             Fixtures and harness modules that tests require
├── fixtures/            Static test inputs (TOML, JSON, …)
├── meta/<topic>/        Source-scanning invariants and harness self-tests:
│                        architecture, boot, shutdown, corpus, gestures,
│                        harness, lua_safety, menu, regressions, runloop,
│                        shell_quoting
├── unit/
│   ├── adapters/<family>/         contracts, file_system, keyboard, …
│   ├── infra/<area>/              config, logger, preferences, toml, …
│   ├── modules/<module>/<part>/   keylogger, keymap, llm, gestures, …
│   ├── platform/remap/<part>/     config, generator, lease, watchers, …
│   └── ui/<surface>/              menu/<submenu>/, tooltip, onboarding, …
├── e2e/                 Stubbed virtual-keyboard and boot scenarios
├── bench/               Benchmarks, never run by the unit suite
└── integration/         Mac-only tests run inside Hammerspoon
```

Put a new test in the folder of the code it exercises. Open a subfolder
rather than letting one folder grow past a few dozen files, and split a test
file along its `describe` blocks before it passes about 800 lines; a prelude
the parts share goes to `tests/support/<same path>/<name>_fixture.lua`, and
each part loads it fresh so no state leaks between files.

## Running locally

### macOS / Linux

```bash
brew install lua             # macOS
sudo apt install lua5.4      # Debian/Ubuntu

cd static/ergopti_plus/macos
lua tests/run.lua
```

### Windows

Install Lua 5.4 via [scoop](https://scoop.sh/) or [chocolatey](https://chocolatey.org/):

```powershell
scoop install lua
# or
choco install lua
```

Then:

```powershell
cd static\ergopti_plus\macos
lua tests\run.lua
```

### One file or one shard

```bash
lua tests/run.lua --only tests/unit/modules/keymap/registry/test_registry.lua
lua tests/run.lua --module=menu_llm
```

`--module` runs one group of `tests/support/module_groups.lua`: meta, core,
modules, menu_llm, menu_input, ui and the catch-all other. CI runs each group
as its own job; together they are exactly the whole suite
(`tests/meta/harness/test_module_groups.lua`).

### With busted (optional)

If [busted](https://lunarmodules.github.io/busted/) is installed (`luarocks install busted`),
test files will run under it transparently — they use only `describe`/`it`
constructs from `tests/helpers`.

## What each layer covers

| Directory        | Purpose                                                                                                                            |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `meta/`          | Invariants no runtime call can check: boot order, teardown paths, ports, Lua and Hammerspoon foot-guns, the test harness itself.   |
| `unit/adapters/` | The OS-isolation layer, one folder per port family, plus the cross-driver contract vectors.                                        |
| `unit/infra/`    | Infrastructure: configuration, preferences, logger, TOML, file watchers, i18n, lifecycle.                                          |
| `unit/modules/`  | Domain modules: keymap, keylogger, llm, gestures, shortcuts, dynamic_hotstrings, hotstrings, updater, diagnostics.                 |
| `unit/platform/` | The Karabiner remap bridge.                                                                                                        |
| `unit/ui/`       | Windows, dialogs, tooltips and the tray menu.                                                                                      |
| `integration/`   | Mac-only — exercised via a "Run Self-Tests" menu item inside Hammerspoon to validate end-to-end behavior with the real `hs.*` API. |

## Updating snapshot fixtures

Snapshot tests under `tests/unit/platform/remap/` compare generated output
against committed `.expected.json` files in `tests/fixtures/karabiner_configs/`.
To regenerate after an intentional change:

```bash
UPDATE_SNAPSHOTS=1 lua tests/run.lua
git diff tests/fixtures/karabiner_configs/   # review carefully!
```

Commit the fixture update only when the diff matches the intended change.

## CI

GitHub Actions runs the full suite on every push/PR — see the `test-hs` job of
`.github/workflows/ci-macos-unit.yml`, the `Unit tests` stage that opens the
macOS lane (`ci-macos.yml`). The job installs Lua 5.4 and luacheck, runs
`tests/run.lua` with Lua 5.4. The separate `e2e-hs` job of
`.github/workflows/ci-macos-e2e.yml` then runs `tests/e2e/run_e2e.lua` as
`macOS / E2E tests / Virtual-keyboard replay (stubbed)`. Packaging waits for
both suites, so a red suite spends no macOS runner time. Installation scenarios
consume the uploaded package; the final verdict checks their completeness.

## Coverage status

`lua tests/run.lua` prints the module and case totals as it runs, and that run
is the inventory. There used to be a `COVERAGE.md` here restating them by hand;
it was deleted once it claimed "keylogger: 0% covered" against 66 keylogger test
files and "ui/: 0% covered (intentional)" against 118. A hand-written census of
a suite that grows every week is wrong within a fortnight and, being prose,
fails no test when it goes wrong — see `docs/TESTING.md`, which states the rule
this follows.
