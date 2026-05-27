# E2E Plan — Real Hammerspoon Keystroke Injection (macOS)

## Status: Deferred — architectural constraint

`run_e2e.lua` exercises the full expansion pipeline in a headless Lua process
using the existing stub layer.  This document describes **what would be needed**
to promote that to a real `hs.eventtap.keyStroke` injection test on a live macOS
machine, and exactly what is blocking it on GitHub Actions today.

---

## What a real E2E run looks like

```
macOS machine (GUI session)
  └─ Hammerspoon loaded (via `open -a Hammerspoon`)
       └─ Driver config loaded with test hotstrings
            └─ hs.eventtap.keyStroke injects trigger chars into a target app
                 └─ Target app's text field is read via Accessibility API
                      └─ Asserted against expected replacement
```

### Key hs.* APIs involved

| API | Role |
|-----|------|
| `hs.eventtap.keyStroke(mods, key)` | Inject one keystroke (key-down + key-up) |
| `hs.eventtap.keyStrokes(text)` | Inject a string of characters |
| `hs.application.open("TextEdit")` | Launch the target app |
| `hs.axuielement` | Read back the text field content via Accessibility |
| `hs.timer.usleep(ms)` | Wait for the async expansion to complete |

### Sketch of a test scenario

```lua
-- In a Hammerspoon console / `hs -c` invocation:
local app = hs.application.open("TextEdit")
hs.timer.usleep(500000)  -- 500 ms for app to become foreground
hs.eventtap.keyStrokes("btw")
hs.eventtap.keyStroke({}, "space")
hs.timer.usleep(100000)  -- 100 ms for expansion to fire
local field = hs.axuielement.applicationElement(app):find("AXTextField")
assert(field:attributeValue("AXValue") == "by the way ")
```

---

## Why this is not wired into CI today

### Constraint 1 — No WindowServer on GitHub Actions macOS runners

GitHub Actions `macos-latest` runners run as a non-GUI `daemon` process.
`hs.eventtap.keyStroke` calls `CGEventPost(kCGSessionEventTap, …)` which
requires a Quartz WindowServer session.  Without one the call silently
no-ops — no keystroke is delivered, no expansion fires.

**Evidence**: the `test_hammerspoon.yml` CI workflow uses `lua5.4` (not
`Hammerspoon.app`) for exactly this reason — all existing HS tests run under
plain Lua with the stub layer.

### Constraint 2 — Hammerspoon cannot be launched headlessly

`hammerspoon --test` mode does not exist.  The `hs` CLI binary exposes a
`-c <lua>` flag for one-shot evaluation but it still requires a running
Hammerspoon instance connected to a WindowServer session.

### Constraint 3 — Accessibility API requires screen recording / accessibility grants

Reading a text field via `hs.axuielement` requires the
`com.apple.security.automation.apple-events` entitlement and the user to have
granted Accessibility access in System Preferences.  GitHub Actions runners
cannot be pre-granted these permissions.

---

## Unblocking path (future work)

| Step | What to do |
|------|-----------|
| 1 | Use a **self-hosted macOS runner** with a persistent GUI session (e.g. a Mac mini with `act` or the GitHub self-hosted runner agent). |
| 2 | Pre-install Hammerspoon and grant Accessibility access once on that machine (`tccutil reset Accessibility com.hammerspoon.Hammerspoon`). |
| 3 | In CI, launch HS via `open -a Hammerspoon`, wait for the IPC socket (`~/.hammerspoon/ipc.sock`) to appear, then issue `hs -c 'dofile("tests/e2e/run_e2e_live.lua")'`. |
| 4 | `run_e2e_live.lua` (to be created) would: open TextEdit, inject keystrokes via `hs.eventtap`, read back via `hs.axuielement`, and call `os.exit(fail_count > 0 and 1 or 0)`. |
| 5 | Wire that into a new `e2e_hammerspoon.yml` workflow that runs only on the self-hosted runner tag. |

---

## Coverage provided by `run_e2e.lua` today

`run_e2e.lua` covers the following layers:

- **Registry** — `add`, `sort_mappings`, `mappings_for_tail` (real module, no stub).
- **Expander** — `try_expand` path including word-boundary check, backspace count,
  and `hs.eventtap.keyStrokes` call (real module, stub intercepts the emission).
- **Corpus vectors** — all 14 vectors from `_shared/tests/corpus/hotstrings/vectors.json`.

The only layer NOT covered is the OS-level CGEventPost round-trip and the
Accessibility read-back — that 5 % is what the self-hosted runner approach above
would add.
