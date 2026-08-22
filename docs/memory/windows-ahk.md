<!-- docs/memory/windows-ahk.md -->

# Windows and AutoHotkey memory

## Source and parser hazards

### feedback-ahk-source-encoding

Every `.ahk` source file is UTF-8 with BOM and LF endings. Encoding drift can
stop parsing mid-file and look like missing tests; always run the encoding gate.

### feedback-ahk-ui-syntax-validation

Some UI modules are outside the headless unit include graph. Validate the real
entry point or the dedicated startup/parse smoke after changing them.

### project-ahk-v2-semicolon-in-string

In AHK v2, a space followed by `;` can start a comment even inside a quoted
string. Build literal semicolons without that lexical sequence.

### project-ahk-keyword-as-variable-hangs-the-parser

Reserved words used as identifiers can make parser diagnostics misleading.
Avoid keyword-like local names and validate with the real v2 executable.

### project-ahk-v2-static-unset-unreadable

An unset static is not a safe sentinel when reading it raises. Initialize
explicitly or guard the variable itself before access.

### project-ahk-isset-requires-variable-load-crash

`IsSet(obj.prop)` attempts to load the property and can fail at load time. Use a
map/key or object-own-property check appropriate to the value's representation.

### project-ahk-numeric-string-equals-false

AHK coercion makes numeric-looking strings surprising in boolean comparisons.
Use explicit string or numeric normalization at configuration boundaries.

### project-ahk-map-delete-raises-on-missing-key

`Map.Delete` is not an idempotent cleanup operation. Check `Has` when absence is
an accepted state.

## Startup and callbacks

### project-ahk-entry-smoke-is-the-startup-proof

Unit includes and compiler parsing do not execute the resident auto-execute
thread. The full startup smoke must launch the real entry with isolated fresh
and existing configs, pump deferred timers, require readiness, and reject ERROR
logs after readiness.

AHK v2's `Func` is a class, not the v1 string resolver: `Func("Callback")`
raises `ValueError: Invalid base`. Return a local wrapper's `.Bind()` when the
real callback is outside an isolated test include graph.

### project-ahk-loop-capture-copy-freezes-nothing

Copying a loop variable into another outer local does not freeze it for a
closure. Bind the current value as an argument with `.Bind()`.

### project-ahk-settimer-reenters-during-file-io

AHK pumps messages during some blocking file operations. A timer that schedules
its next tick before committing state can re-enter; publish state first or use
an explicit in-flight guard.

### project-ahk-menu-dispatcher-error-swallow

Menu-dispatch bypasses must rethrow callback failures after logging. A local
catch that returns success destroys crash evidence.

### project-ahk-invariant-incomplete-application

When an invariant fixes one callback family, enumerate every sibling producer.
The recurring defect class is a correct guard applied to only one timer, hook,
menu, or async completion path.

### project-ahk-guard-tests-must-loop-the-class

Regression tests for cross-cutting guards must enumerate the whole callback
class and assert a nonzero subject count.

## Input, suspension, and menus

### feedback-ahk-suspend-prefix-latch

AHK custom-combination prefix-down state can survive `Suspend`. Clear or avoid
the latch at its owner; synthetic key-up events do not reset internal prefix
state.

### project-suspend-pause-invariant

Native `Suspend` disables hotkeys but not InputHooks, timers, or `OnMessage`.
Every such callback that can type, display UI, record activity, or start network
work must explicitly honor `A_IsSuspended`.

### project-updater-nonblocking-http

Background HTTP must be asynchronous because a synchronous native call can
freeze the cooperative AHK thread and keyboard handling. User-initiated waits
may remain synchronous when their UI contract is explicit.

### project-ahk-updater-async-ownership

Updater ownership spans construction, dispatch, polling timer, terminal
callback, and epoch. Generation checks only at entry do not reject stale
completions.

### updater-download-suspend-guard

Background downloads are observable work and must not begin or publish UI while
paused. Recheck suspension at dispatch and completion boundaries.

### project-ahk-menu-dispatcher-drop

Raw AHK tray callbacks have historically dropped clicks on this driver. Every
actionable item goes through `RegisterMenuItem` and the menu dispatcher.

### project-ahk-probing-synthetic-input

Tests of injected input must prove provenance and destination, not merely that a
key-shaped event appeared in a hook.

## Files, configuration, and UI hosts

### project-ahk-unreadable-config-persists-defaults

An unreadable config is not an empty config. Propagate read failure and suppress
saves; otherwise defaults can overwrite a temporarily locked user file.

### project-windows-at-rest-store-is-data-sql

Windows persists metrics in `data.sql`; `db.sqlite` is a rebuilt cache, not the
authoritative at-rest store.

### project-webview2-bridge-gotchas

WebView2 hosts must retain message subscriptions, wait for navigation readiness,
serialize bridge payloads with the shared adapter, reject stale generations,
and release native handlers on teardown. A page loading is not proof that its
bridge is alive.

### project-typing-latency-tooltip-coldstart

Do not move WebView2 creation or cold native window construction onto the typing
path. Reuse only resources whose lifecycle and stale-state behavior are proven.

### project-metrics-ui-live-foreground-contract

Metrics UI snapshots must project the currently open foreground interval; disk
state alone lags the user's live session.
