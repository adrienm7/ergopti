# Hammerspoon Driver — Test Suite

Comprehensive Lua unit, meta, and integration tests for the code under
`static/drivers/hammerspoon/`. The suite is **runnable on Linux, macOS and
Windows** under plain Lua 5.4 — no external dependencies required.

## Layout

```
tests/
├── run.lua                 Test runner entry point (zero-dep)
├── stubs/
│   └── hs.lua              Hammerspoon API shim
├── helpers/
│   └── init.lua            Shared assertions, mini test runner, fixture loader
├── fixtures/               Static test inputs (TOML, JSON, …)
├── meta/                   Architectural-invariant checks (file headers, etc.)
├── unit/                   Per-module unit tests
└── integration/            Mac-only end-to-end tests run inside Hammerspoon
```

## Running locally

### macOS / Linux

```bash
brew install lua             # macOS
sudo apt install lua5.4      # Debian/Ubuntu

cd static/drivers/hammerspoon
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
cd static\drivers\hammerspoon
lua tests\run.lua
```

### With busted (optional)

If [busted](https://lunarmodules.github.io/busted/) is installed (`luarocks install busted`),
test files will run under it transparently — they use only `describe`/`it`
constructs from `tests/helpers`.

## What each layer covers

| Directory       | Purpose                                                       |
|-----------------|---------------------------------------------------------------|
| `meta/`         | Architectural invariants — file headers, banner alignment, logger pairing, defaults uniqueness. Most are **warnings**, never hard failures, so legitimate refactors don't break the build. |
| `unit/lib/`     | Pure-function libraries (`color_utils`, `text_utils`, `toml_reader`, `keycodes`, `logger`, `perf`, …). |
| `unit/modules/` | Domain modules: keymap, llm parser/profiles/api, karabiner config, gestures, dynamic_hotstrings, keylogger, shortcuts. |
| `integration/`  | Mac-only — exercised via a "Run Self-Tests" menu item inside Hammerspoon to validate end-to-end behavior with the real `hs.*` API. |

## Updating snapshot fixtures

Snapshot tests under `tests/unit/modules/karabiner/` compare generated output
against committed `.expected.json` files in `tests/fixtures/karabiner_configs/`.
To regenerate after an intentional change:

```bash
UPDATE_SNAPSHOTS=1 lua tests/run.lua
git diff tests/fixtures/karabiner_configs/   # review carefully!
```

Commit the fixture update only when the diff matches the intended change.

## CI

GitHub Actions runs the full suite on every push/PR — see
`.github/workflows/lua-tests.yml`. The workflow installs Lua 5.4 and luacheck,
then runs `lua tests/run.lua`.

## Coverage status

See `tests/COVERAGE.md` for a per-module breakdown of what is and isn't covered.

The current suite holds **~380 unit-test cases** across ~32 test files, plus
six architectural meta-tests. Roughly 55–60% of the testable surface is
covered; the remaining gaps are documented (with reasons) in `COVERAGE.md`.
