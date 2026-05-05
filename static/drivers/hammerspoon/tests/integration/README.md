# Integration Tests (Mac-only)

These tests run **inside Hammerspoon** against the real `hs.*` API. They cannot
run on Windows or Linux CI because they rely on macOS-specific facilities
(Karabiner, NSWorkspace, real keystroke synthesis, etc.).

## How to run

1. In Hammerspoon, open the console.
2. Type:

```lua
dofile(hs.configdir .. "/tests/integration/run_in_hs.lua")
```

3. Watch the console for `PASS` / `FAIL` lines.

These tests intentionally exercise side effects (mapping registration, menu
construction) so they should be run on a non-critical user profile.

## Why these aren't in CI

CI only runs the unit + meta tests under `tests/unit` and `tests/meta`. Anything
requiring the real Hammerspoon process is reserved for manual smoke testing
before a release.
