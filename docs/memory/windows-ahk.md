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

### project-ahk-equality-and-case-identity

Identity rules disagree across the language and were measured, not recalled,
on the shipped interpreter (AutoHotkey v2.0.26): the `==` operator compares
plain strings **case-sensitively** (v1 muscle memory says otherwise; there is
no `===` — writing one is a load-time `Missing operand` error), while
`StrCompare(a, b)` and `InStr` default to **case-insensitive**, and object
property names are always case-insensitive. `Map` adds two more splits: keys
are case-sensitive by default, and integer/string key types are distinct
slots (`m[1]` never finds `m["1"]`). Pick one identity rule per boundary and
pin it with a mixed-case test vector; rewriting a check from `==` onto
default `StrCompare`, or from a `Map` index onto property access, silently
loosens or tightens matching. Concrete near-miss: an audit refutation of a
duplicate-API-entry-ID wedge was argued from remembered v1-style `==`
semantics; measuring showed validator `Map.Has` dedup and consumer `==`
matching already agreed, killing the candidate.

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

## Tap-holds and synthetic modifiers

### project-ahk-modifier-name-hotkey-shadows-scan-code

`RAlt::` (also with `~ * $`, or as `vkA5`) is its own hotkey identity, hooked on
the modifier's standard scan code. When none of its variants is eligible, AHK
does not fall back to the `SC138` variants of the same key, so the Kana-layout
AltGr tap-hold never fired (measured, v2.0.26). `$` and `~` do not form an
identity; `*` does. Action: declare modifier-key hotkeys by scan code only;
`test_modifier_hotkeys_single_identity.ahk` bans the name form.

### project-ahk-a-priorkey-is-a-layout-name

`A_PriorKey` is `GetKeyName` of the recorded vk and sc through the active
layout: never `SCxxx`, `Backspace` rather than `BackSpace`, `^` for the Kana
AltGr, and `==` compares it case-sensitively. Action: guard taps with
`TapHoldPriorKeyIsSelf(KeyId)`, never a literal name.

### project-ahk-send-lifts-modifiers-it-did-not-press

Without `{Blind}`, a Send lifts every modifier held by another source (a
physical key, a `~` pass-through hold) around its key, but keeps the ones this
process pressed with `{X Down}` (measured). A bare tap output therefore dropped
a held Shift while CapsLock held as Ctrl survived. Action: send keystroke taps
through `TapHoldEmitKeyTap`, which adds `{Blind}` only when a modifier is down,
so the bare `{BackSpace}` the hotstring buffer matches is unchanged. Keep
`{Blind}` out of the shared gesture callbacks: gestures and shortcut slots fire
them while their own carrier modifier is held.

### project-ahk-hotkey-without-wildcard-ignores-held-modifiers

A hotkey without `*` does not fire while any extra modifier is logically down,
the script's own level-0 synthetic holds included (measured); the key then
performs its native function and the tap and hold are lost. Action: every
tap-hold variant on CapsLock and the modifier keys carries `*`
(`test_tap_hold_hotkeys_admit_held_modifiers.ahk`). Tab, Space, Enter, Escape,
Backspace and Delete stay the key itself under a held modifier on every driver
(Linux `NATIVE_UNDER_MODIFIER`, the macOS rules); do not add `*` to their
tap-only variants.

### project-ahk-lone-alt-win-release-needs-a-mask

Releasing a synthetic Alt or Win that no key followed puts classic windows in
menu mode or opens Start, and the next tap output lands there. Action: send
`TextSendMenuMask` (`{Blind}{vkff}`, the driver's `A_MenuMaskKey`) before the
release, as `_TapHoldReleaseOwnedModifier` does; Linux masks with KEY_F24.

### project-ahk-kana-altgr-is-sc138-not-ralt

On Kana-style layouts VK_RMENU has no scan code: a synthetic RAlt is a plain Alt
that enters menu mode, and the AltGr key is SC138. Action: resolve AltGr through
`KS_AltGrKeyName()`, never a literal `RAlt`.

### project-ahk-worker-processes-inherit-driver-identity

AHK creates the tray icon, the main window and every load-time hotkey before a
script's first statement, so a worker re-running the entry looked like a second
driver and armed a second keyboard hook. Action: keep `#NoTrayIcon` at the
entry and reveal the icon on the driver path only; a worker suspends and
retitles itself first (`WinSetTitle` on the pure `A_ScriptHwnd` reaches the
hidden window without a DllCall).

## Files, configuration, and UI hosts

### project-ahk-unreadable-config-persists-defaults

An unreadable config is not an empty config. Propagate read failure and suppress
saves; otherwise defaults can overwrite a temporarily locked user file.

### project-ahk-strict-toml-validation-needs-a-legacy-migration

Strict manifest literal validation without a migration path for the writer's
own legacy spellings bricks the installed base: every legacy key is skipped
AND the rejected-override latch then blocks all later saves, including the
toggle that would have canonicalized the file. Accept exact legacy spellings
with user intent, count them as migrated (never as rejected), and let the next
typed save canonicalize them. The 2026-09 legacy 0/1 boolean migration in
ApplyConfigToml is the reference case.

### project-windows-at-rest-store-is-data-sql

Windows persists metrics in `data.sql`; `db.sqlite` is a rebuilt cache, not the
authoritative at-rest store.

### project-metrics-projection-is-restored-not-rebuilt

Every metrics projection runs in a disposable worker, so the reader cache is
cold unless the previous worker's image is restored from
`<metrics>/cache/reader.sqlite`. A full rebuild is O(all history) — 16 min on an
815 MB store, dominated by walking every raw event through the stateful walker —
so it must stay the fallback, never the normal path. Only the worker may write
the image: the resident driver's handle carries live-walker deltas that
`data.sql` alone cannot reproduce. A refresh clears and replays whole affected
days rather than folding in just the tail, because the persisted image does not
carry the walker's cross-event context; the cost of that choice is that n-grams
no longer chain across a day boundary. JSON distributions must accumulate across
flushes even during cold replay: cold/warm equality alone can compare two equally
truncated distributions, so pin conservation across batch boundaries as well.

When the cold build is unavoidable on a store above 32 MB, a worker rebuilds
newest day first (`keylogger_reader_rebuild.ahk`): it reads ledgers backward
from `-- === ingest batch` boundaries, keeps first-copy-wins for reused keys
with temporary BEFORE INSERT triggers, and rolls up a day once every batch
ingested on or after it has run. Rounds use the warm-refresh date-scoped
rollups, so the result has warm semantics (no n-gram chain across rounds).
Progress, partial snapshots (`<prefetch>.partial`) and a once-a-minute
checkpoint (`cache/rebuild.sqlite`) let the page show recent days within
seconds and let a worker killed by a driver reload resume. A leftover
main-schema payload table is dropped from a private copy (upgrade), never a
reason to rebuild.

Clear ordered typing events belong only to the reader's MEMORY-only TEMP table,
which main-database backup excludes. Cache format 4 persists per-event numeric
character counts instead; SQL rollups can reuse them without decrypting old
history. A worker populates clear payloads only for replay dates, while a resident
delta needs counts for missing event identities. Older cache formats are closed
and discarded before rebuilding. Never fix a plaintext cache by writing clear
pages to a stage and deleting them afterward: failed stages would still expose
the payload. The native cache-encryption tests cover the saved file, warm scope,
obsolete-image rejection, and failed publication recovery.

### project-metrics-reserved-order-is-not-append-order

`KL_AllocEventId` and `KL_AssignStableEventId` preserve reserved screen order for
typing, accepted output and shortcuts. Wall-clock correction may move timestamps
backward; changing logical replay or latest category selection to timestamp
order breaks that contract. `test_keylogger_llm_accepted_metrics.ahk` covers
cross-boundary input order; `test_klr_category_order.ahk` covers category retention
through cold replay and resident SQL refresh. This does not make IDs a journal
offset: delayed or imported tail rows can have IDs below the stored maximum.
Discover affected days from consumed tail SQL, never `id > max(id)`.

### project-file-write-buffer-is-not-an-os-receipt

AHK v2.0.26 buffers small `File.Write` **and `RawWrite`** calls. Their byte
counts can mean buffered acceptance, not an OS write; `Close` and `.Handle`
discard the subsequent buffer-flush failure. A successful native
`FlushFileBuffers(File.Handle)` can therefore bless an empty file. Use checked
`WriteFile` on the same freshly opened handle before any buffered writes, and
check both its Boolean result and byte count. Reject a non-UTF-8 effective file
encoding before native UTF-8 append: opening with `UTF-8-RAW` still detects an
existing UTF-16 BOM. Keep low-level writers logger-free. A shared `LockFileEx`
lock on a second real handle reproduces the false receipt without disk exhaustion
or a fake File object; pair it with unlocked multibyte controls. See vendor
`TextIO.cpp` (`TextStream::Write`) and `TextIO.h` (`FlushWriteBuffer`, `Handle`).

### project-webview2-bridge-gotchas

WebView2 hosts must retain message subscriptions, wait for navigation readiness,
serialize bridge payloads with the shared adapter, reject stale generations,
and release native handlers on teardown. A page loading is not proof that its
bridge is alive.

### project-typing-latency-tooltip-coldstart

Do not move WebView2 creation or cold native window construction onto the typing
path. Reuse only resources whose lifecycle and stale-state behavior are proven.

### project-tooltip-units-and-coordmode

AHK `CoordMode` is per thread and defaults to `Client`, so every
`CaretGetPos`/`MouseGetPos` feeding a screen placement must set `Screen` in the
same function. Tooltip Guis are DPI-scaled: measure text in layout units
(`_TooltipMeasureTextSize` divides by DPI/96) and convert sizes and shared offsets
to physical pixels only at placement (`_TooltipPlaceOnScreen`).

### project-metrics-ui-live-foreground-contract

Metrics UI snapshots must project the currently open foreground interval; disk
state alone lags the user's live session.
