# ErgoptiPlus Hammerspoon audit — 2026-08-29

## Audit identity

- Audited commit: `094d4a955eb150fec8e872b67f66d603e342859c`
- Scope: `static/ergopti_plus/macos/`
- Branch used for fixes: `fix/hammerspoon-audit-2026-08-29`
- Canonical worktree: `../ergopti-fix-hs`

This report is immutable evidence for the code at the audited commit. Finding
completion is derived from `Audit-Finding` Git trailers, not by editing this
document.

## Executive summary

Seven actionable defects were confirmed. Three can block or delay Hammerspoon's
single run loop, including one earlier regression test that incorrectly treated
`hs.timer.doAfter(0, ...)` as a worker-thread boundary. Four delete callback
failures or falsely settle user transactions, leaving saved state, downloads,
gesture actions, or live metrics inconsistent with what the UI implies.

The baseline Hammerspoon suite passed, and the mechanical false-green scanner
reported no known tautology, vacuous-absence, dead-test, `pcall`-only,
corpus-skip, or unfloored-scan violations. Manual review nevertheless found a
human-judgment false green in the MLX boot test: it pins the broken deferral
mechanism and asserts the opposite of Hammerspoon's run-loop semantics.

## Scope and coverage

The audit covered the complete macOS driver inventory (247 production Lua
candidates after excluding tests, vendor code, and generated output), plus the
Swift launcher and helper sources. Dedicated whole-tree sweeps covered:

- direct `hs.task.new` ownership and GC retention;
- timer construction, publication, cancellation, cleanup debt, and callback
  generation fences;
- watchers, event taps, input-source transitions, CapsWord, and pause/reload
  cleanup;
- synchronous subprocess calls reachable from boot or live UI callbacks;
- `pcall`/`xpcall` callback visibility and native boolean/nil return contracts;
- clipboard and synthetic-input transactions;
- all controlled reload/exit paths and the native `hs.shutdownCallback` path;
- LLM warmup, discovery, profile persistence, model selection, and preview
  hand-offs;
- recent Hammerspoon audit fixes and their sibling sites.

Evidence executed before the report was frozen:

- `node tools/test/find-false-greens.cjs` — passed with zero mechanical
  findings in every category;
- `npm run test:hs` — passed at the audited SHA;
- focused source and behavioral harness review for each finding below;
- official Hammerspoon API-contract verification for `hs.execute` and
  application launch return values.

## Confirmed findings

### HS-194 — Singleton selection windows falsely commit rejected callbacks

Severity: **high**. Confidence: **high**. Guarantees: **G1, G2**.

`ui/prompt_editor/init.lua` marks the context settled before invoking `on_save`,
discards both the protected-call status and the callback's explicit `false`,
then closes the window. Production profile callbacks return `false` when
persistence or activation refuses. `ui/action_picker/init.lua` and
`ui/model_browser/init.lua` have the same close-before-callback transaction,
including callers whose mutation APIs return `false`.

Reproduction: open any affected singleton with a callback that returns `false`
or raises, then deliver the matching bridge save/confirm/select message. The
window closes, the mutation is absent, and a retry in the same context is
impossible. A prompt callback that re-enters the bridge also needs an in-flight
fence so delaying settlement does not duplicate the save.

Regression boundary: drive the real bridges. Refusal or exception must keep the
current context open and retryable; success must close exactly once; re-entrant
delivery must invoke the callback at most once; exceptions must reach the
central logger.

### HS-195 — Deferred MLX boot cleanup still blocks the Hammerspoon run loop

Severity: **high**. Confidence: **high**. Guarantees: **G4**.

`modules/llm/boot_cleanup.lua` runs a synchronous `hs.execute` shell containing
`lsof`, `curl --max-time 1`, process enumeration, and a possible `sleep 0.3`.
`init.lua` wraps it in `hs.timer.doAfter(0, ...)`, but timer callbacks execute on
the same Hammerspoon run loop. The existing
`tests/meta/test_init_mlx_cleanup_after_taps.lua` therefore certifies a false
mechanism: it claims the wrapper prevents the shell from blocking after both
input taps are live.

Reproduction: let the cleanup reach the curl timeout or nuke branch and fire the
zero-delay callback. Hammerspoon cannot process another timer, WebView message,
or input event until the shell returns.

Regression boundary: the cleanup must use the retained asynchronous task
adapter, never `hs.execute`; the backend bootstrap must wait for the cleanup's
terminal callback so removing the block does not create a port-state race; task
construction/start failures must remain visible and release the boot gate.

### HS-196 — Download terminal action runs AppleScript synchronously

Severity: **high**. Confidence: **high**. Guarantees: **G4**.

The `terminal` WebView message in `ui/download_window/init.lua` calls
`hs.execute` inline to launch `osascript`. This is a live user action after the
typing event tap is armed; Terminal/Launch Services startup can hold the only
Hammerspoon run loop until completion. The existing interactive-blocking
ratchet covers shortcut and gesture directories but omits this WebView action.

Reproduction: capture the real download bridge, make the osascript process slow,
and post `terminal`. The bridge callback does not return and the driver cannot
process input until the child exits.

Regression boundary: the real bridge must dispatch through the asynchronous
shell adapter, preserve the exact AppleScript payload, report launch/completion
failure, and never call `hs.execute`.

### HS-197 — Input-source notifications synchronously spawn `defaults`

Severity: **medium**. Confidence: **high**. Guarantees: **G4**.

`platform/remap/watchers.lua` already owns a generation-fenced asynchronous
`/usr/bin/defaults` reader for its fallback poll. The primary
`inputSourceChanged` subscriber instead calls the synchronous
`read_current_layout_from_hitoolbox()` helper from the notification callback.
Every real layout switch can therefore stall the run loop on process startup
and preference I/O.

Reproduction: start the watcher with a controllable broker, block
`hs.execute`, and fire the installed callback. It cannot return or arm the
debounced rebuild until the subprocess completes.

Regression boundary: both notification and poll paths must share the existing
asynchronous, single-owner read transaction, retain its watchdog and generation
fences, and fall back visibly when acquisition fails.

### HS-198 — WebView controller callbacks delete exceptions

Severity: **medium**. Confidence: **high**. Guarantees: **G1, G2**.

The download window's cancel/resolve/retry hooks, the hotstring editor's
preference and focus hooks, and the hotstrings configuration window's refresh
hook invoke external controllers through bare `pcall` and discard the result.
These callbacks perform cancellation, persistence, focus-state, and menu-refresh
work. A throw is converted into an apparent successful click with no searchable
diagnostic.

Reproduction: install a callback that raises, then deliver the corresponding
real bridge message or native close callback. Execution resumes but no central
error is emitted; for download cancellation, the child operation may continue
after the user asked to stop it.

Regression boundary: exercise the real bridge/lifecycle callbacks with throwing
controllers; each must be invoked exactly once, its exception must be contained,
and an ERROR with operation context must reach the central logger.

### HS-199 — Gesture frame failures are silently discarded

Severity: **medium**. Confidence: **high**. Guarantees: **G1, G2**.

`modules/gestures/engine.lua` uses bare `pcall` for the registered
`_any_touch_hook` and for two `commitGesture` paths. A failing CapsWord touch
hook leaves CapsWord active, and a failing commit loses the configured gesture,
while state reset makes both failures look like an ordinary ignored frame. The
touch hook runs at frame frequency, so visibility must also avoid log flooding.

Reproduction: register a throwing touch hook and process a non-empty frame, or
inject a throwing action into a completed gesture. The call is contained but no
file-log error identifies the lost action.

Regression boundary: both paths must preserve containment, emit the first
contextual error, throttle repeated frame-hook failures, and continue resetting
gesture state safely.

### HS-200 — Keylogger listener failures silently stale live dashboards

Severity: **medium**. Confidence: **high**. Guarantees: **G1, G2**.

`modules/keylogger/log_manager.lua` explicitly says ingest-listener errors are
swallowed and calls every listener through an unchecked `pcall`. The live typing
and apps dashboards register `push_live_update` here; one exception makes that
dashboard miss the committed database revision without any log explaining why.
The log-manager shutdown completion callback has the same invisible hand-off.

Reproduction: register one throwing listener and one successful listener, then
run a successful `ingest_once()`. Both are invoked, but the first failure emits
no ERROR and the affected dashboard remains stale.

Regression boundary: a throwing listener must not prevent later listeners, its
first failure must reach the file logger with stable context, repeated ingest
ticks must be throttled, and stop callbacks must use the same visible boundary.

## Performance provenance

HS-195, HS-196, and HS-197 are code-derived blocking findings. Their proof is
the synchronous API boundary and live call graph, not a fabricated wall-clock
benchmark. The MLX command itself supplies a one-second curl timeout and a
0.3-second branch sleep; `hs.execute(..., true)` also requests a user-shell
environment. Hammerspoon documents `hs.execute` as a synchronous command API.

The Windows audit host has no live macOS Hammerspoon log directory at the
resolved configured path, so no runtime distribution, tail-latency percentile,
event-tap disable incident, CPU sample, or memory-growth claim is made. G4 must
be re-measured on a real Mac after implementation.

## Memory watch-list

- Deferred keylogger startup is described in code as roughly 1.3 seconds of
  SQLite/rotation work on the main run loop. It remains a performance hypothesis
  until a real Mac log and profile can separate driver work from cold filesystem
  effects.
- Text-at-rest encryption shells out for encryption and currently also hashes
  IV input through OpenSSL even though the adapter exposes `hs.hash`. This may be
  expensive during ingest, but no runtime sample was available.
- Old-log purge runs in-process after a timer deferral. Its previous subprocess
  explosion is gone; directory size and real duration should still be watched.
- UI/menu code contains additional best-effort `pcall` sites around native
  cleanup or notifications. Only live controller hand-offs with a reproducible
  lost action were promoted to HS-198.

## Refuted hypotheses

- Direct raw task ownership is not dispersed across domain code: production
  `hs.task.new` construction is concentrated in the task lifecycle and shell
  runner adapters, and the whole-tree GC-retention tests cover their live pins.
- `adapters.app_launcher.launchWithArgs()` ignores a shell result, but its shared
  port contract is intentionally void/fire-and-forget and it has no production
  caller. Tightening it would be hardening, not a reproduced live bug.
- Treating `nil` from `hs.application.launchOrFocus` as success looked suspect,
  but the documented native contract returns a boolean; `nil` belongs only to an
  unfaithful double, not a reachable production outcome.
- The Swift force-unwrap search found only guarded non-empty buffer
  `baseAddress` uses; no reachable launcher crash was established from static
  evidence.
- The previous Hammerspoon audit branch is fully merged into `dev`; this audit
  is not rediscovering an unintegrated patch stack.

## Coverage gaps

- The audit ran on Windows. Hammerspoon itself, CoreGraphics event-tap timing,
  WebKit, real `hs.task`, the Swift launcher build, and macOS permissions could
  not be exercised in situ.
- No live Hammerspoon logs existed at the resolved config path, so performance
  validation is code-derived only.
- External binaries and OS services (`defaults`, `osascript`, `curl`, `lsof`,
  MLX, Ollama, Karabiner-Elements) were represented by native-shaped doubles in
  tests, not executed against a user's Mac state.
- Passing headless Lua tests cannot prove AppKit focus, accessibility prompts,
  or actual event-tap recovery. Those remain explicit real-driver validation
  items after the local gates are green.
