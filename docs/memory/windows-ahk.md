<!-- docs/memory/windows-ahk.md -->

# Windows and AutoHotkey memory

## Source and parser hazards

### feedback-ahk-source-encoding

Every `.ahk` source file is UTF-8 with BOM and LF endings. Encoding drift can
stop parsing mid-file and look like missing tests; always run the encoding gate.

### project-ahk-native-fixture-caption-receipts

Tree-owned completion reads its stdout capture with `FileRead(path)` in
`_SR_TreeFinishClaim`, so decoding follows `A_FileEncoding`. A child writing
UTF-8 without a BOM can therefore produce mojibake under a test runner's native
code page. For native caption probes, write the actual `Gui.Title` to a private
UTF-8 receipt and read it with an explicit encoding; retain an ASCII completion
acknowledgement, the exact exit status and strict error checks. Do not change
the general process port's decoding contract to repair one fixture.

### feedback-ahk-ui-syntax-validation

Some UI modules are outside the headless unit include graph. Validate the real
entry point or the dedicated startup/parse smoke after changing them.

### project-ahk-shared-test-helper-must-resolve-in-every-runner

`tests/test_framework.ahk` is included by `run_all.ahk`, `e2e/run_e2e.ahk`,
fixtures and the child probes some tests write to `%TEMP%`. A helper there that
names a function only `run_all.ahk` includes is an unset variable in the other
runners, and AHK v2's default `#Warn VarUnset, MsgBox` raises a hidden load-time
dialog: the child never exits and the suite hangs at the probe test with no
error. Put such helpers in a test file that `run_all.ahk` includes.

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

### project-ahk-dllcall-wstr-is-a-pointer

`DllCall(..., "WStr", "1", ...)` passes the string's address. For a `WCHAR`
parameter (VkKeyScanExW) the callee then reads the address's low bits as the
character: the digit-row probe got -1 on every layout, whose high byte read
as Shift. Action: pass a character as `"UShort", Ord(Char)` and treat -1 as
"not on this layout" (`KS_LayoutDigitsAreShifted`).

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

### project-compiled-first-launch-extraction-takes-seconds

The compiled exe's first launch expands its bundle of several hundred files
through Windows PowerShell's `Expand-Archive`, and only then commits the
staging tree that holds `.bundle-version`. With Defender scanning every file
on a hosted runner this takes seconds, so a fixed deadline on the marker failed
a healthy launch ("did not extract its runtime bundle within 20s", green on
re-run). Action: a launch check detects a blocking dialog by a `#32770` window
of the launched process, never by a wall clock. Before tightening the launch
smoke's hang bound, re-measure from the `OK: ... after N s` lines of recent
step logs; the `windows-launch-evidence` artifact expires after 7 days.

### project-ahk-loop-capture-copy-freezes-nothing

Copying a loop variable into another outer local does not freeze it for a
closure. Bind the current value as an argument with `.Bind()`.

A closure never sees the `for` variable itself either, even when it runs inside
the same iteration: AutoHotkey 2.0 backs the loop variable up and rebinds it
away from the captured cell, so the closure reads the pre-loop value, usually
unset. Inside `AssertThrows` that UnsetError passes whatever the product does.
Move the loop body into a helper whose closure reads a parameter, or use
`.Bind()`. `tools/test/test-ahk-loop-capture.cjs` rejects both shapes.

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

### project-ahk-reload-returns-before-onexit

`Reload()` starts `/restart` and returns in the same tick (measured, v2.0.26);
OnExit runs with reason "Reload" only once the successor has loaded (about a
second for the driver) and asks this window to close. A returned Reload is
therefore never a refusal: reading it as one logged "refused", rolled back the
paths editor, onboarding and reset, and dropped the pause on every successful
reload. If OnExit refuses, the successor keeps waiting and prompts "Could not
close the previous instance of this script. Keep waiting?" until answered.
`ExitApp` is the opposite: it runs OnExit before returning. Action: reload only
through `ReloadPreservingSuspend`; its hand-off launches the successor with an
owned handle, stays pending until OnExit claims it, and on a later refusal
stops the successor and returns the bundle through the caller's `RefusedFn`.
A successor that stops on a load-error dialog (a syntax error in the included
personal shortcuts file) is alive and has not asked to close, so the pending
reload keeps the configuration barrier until someone dismisses that dialog; it
is logged once after `RELOAD_SUCCESSOR_STALL_MS` and never killed, because its
close request may already be queued. Action: when configuration writes stay
blocked after a reload, look for that dialog before suspecting a barrier leak.
A refused reload also spends one of the process's
`LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS` OnExit vetoes, and past the last honored
one the exit goes through the gate that refuses it. Action: a reload nobody
asked for (the layout poll) retries a refusal a few times with a doubling wait,
starts only while `LifecycleShutdownVetoHonored()`, and reports a refused stage
without the "save failed" notice.

### project-ahk-restart-closes-the-newest-window-with-the-title

`/restart` and `#SingleInstance Force` ask ONE window to close: the newest one
whose class and title match the script's main window (`FindWindow`, top of the
Z-order). A detached worker that re-runs the driver entry owns that exact title
from the creation of its window to its first statement, where it retitles
itself: 22 to 34 ms measured on v2.0.26, because the hooks and hotkeys are
installed in between. A successor that finished loading inside that span
closed the worker (exit 0, « no output captured »), then waited
`DRIVER_MUTEX_WAIT_MS` on the mutex the live driver still held and left; the
driver reported « the successor exited without asking this instance to close ».
The two started in the same millisecond because the metrics warm-up chains its
next worker from a completion callback that runs while the reload launches.
Action: no worker starts while `ReloadTerminalHandoffActive()`, and
`LifecycleRetireWorkers` stops the live ones before the successor launches; a
new kind of worker that reuses the entry or the executable joins both. When
that refusal comes back, read `bootstrap.log` for the mutex line and look for
a worker that ended at the same second.

### project-ahk-getmenustate-counts-rows-in-the-high-byte

For a row that opens a submenu, `GetMenuState` returns the row's flags in the
low byte and the submenu's row count in the high byte. `MF_SEPARATOR` (0x800)
is a bit of that count, so a submenu of 8 to 15 rows (24 to 31, ...) read as a
separator and `_MR_NormalizeSeparators` deleted it wherever it ended a menu or
followed a separator, with no log line: Hotstrings › Français lost its magic
key category (8 rows), « Combinaisons de touches » its three families, the
Gestures menu its system status row. Action: test `MF_POPUP` first, as
`TrayMenuIsSeparatorAt` does; when a row is missing from a tray and no
renderer warning names it, dump the live tree (the startup-smoke wrapper
exposes `_DriverStartupSmokeInspect`) before reading the builders.

### project-ahk-a-waiting-thread-cannot-outwait-the-one-it-interrupted

A hotkey or a tray click runs as a new thread that interrupts the current one,
and the interrupted thread resumes only when the new one returns. A thread
that needs something the interrupted one holds (the configuration lease during
a write) can therefore never get it by waiting or retrying in place. The
reload shortcut pressed during the start-up write of config.toml (2 360 ms on
a loaded machine) was refused with « another configuration transaction owns
config.toml » and an error window. Action: return and ask again from a
one-shot timer, as `ReloadDeferralQueue` does for a plain reload (bounded, one
queued at a time); never `Sleep` or loop on a lease inside the request. A
request with callbacks or a borrowed bundle is still refused at once.
A tray click meets this far more often than chance suggests: AutoHotkey runs
no timer while a menu is open, so a save that came due meanwhile (the
start-up full save, thirty seconds after a start) begins the moment the menu
closes and the clicked row's command interrupts it. A category toggle was
lost this way with « another configuration transaction is already in
progress » (2026-10-01). Every menu command, native or rescued by the retry,
now goes through `MenuCommandRun`, which waits for `ConfigWriteLeaseBusy()` to
clear on a one-shot timer (bounded, then the command runs and reports its own
refusal). A new dispatch path must go through it too.

## Input, suspension, and menus

### feedback-ahk-suspend-prefix-latch

AHK custom-combination prefix-down state can survive `Suspend`. Clear or avoid
the latch at its owner; synthetic key-up events do not reset internal prefix
state.

### project-suspend-pause-invariant

Native `Suspend` disables hotkeys but not InputHooks, timers, or `OnMessage`.
Every such callback that can type, display UI, record activity, or start network
work must explicitly honor `A_IsSuspended`.

### project-a-pause-guard-is-not-a-shutdown-debt

A function that refuses to run under a pause returns the same `false` as one
that ran and found work left. A shutdown gate that calls it must tell the two
apart: the navigation owner's preflight took the paused receipt drain for a
debt and refused every reload or exit asked while paused, then « compensated »
by resuming the native hook the pause had suspended. Under a pause a gate
skips the paused step, keeps the proof that reads state (`CanStop`), and
compensates only the fence it took itself. Every refusal names the condition
that refused: the lifecycle line alone says only which owner did.

The same holds for work a pause defers to the resume: check that something
exists for the paused driver to keep. A reload asked while paused restores the
pause from the successor's first watchdog tick, which lands during the
deferred boot build of the tray root; « no rebuild under a pause » then
refused the first root and left the paused driver without its pause row. The
first root publishes under a pause and the watchdog serves it there
(`_TrayRootFirstPublicationPending`); every later rebuild still waits for the
resume. That build then asks owners the pause has suspended: the AI hotkeys
need the native navigation owner, which refuses every plan while paused, so
the first build defers them and `LLM_Menu_OnResume` activates them.

Each gate fixed on this path uncovered the next (shutdown preflight, first
root, AI hotkeys, then the updater's resume step, which required `true` from a
function whose `false` means « nothing retained » and so failed every resume).
The startup smoke's `suspend-marker` fixture is the end-to-end check: it boots
paused, builds the tray root under the pause, lifts the pause and waits for
the deferred hotkeys, and any ERROR line fails it. Before 2026-10-01 it
skipped the build for that fixture, which hid all of the above; extend it
rather than a unit test when a new owner joins the paused boot or the resume.

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

### project-ahk-owned-test-menu-tree-teardown

Deleting a test menu's top-level rows detaches its live submenus. Dispatcher
callbacks that capture those submenu/parent objects then survive until AHK exit
teardown, which can end with STATUS_HEAP_CORRUPTION after all assertions pass.
Release the owned descendants while holding their Menu objects, clear their
rows, and prune their registrations before clearing the parent; see
`_CTC_ReleaseMenu`. Preserve foreign detached registrations: the production
dispatcher deliberately uses ownership beyond tray reachability, so clearing
its global maps would hide a different bug.

### project-ahk-sendinput-falls-back-to-sendevent

SendInput removes the script's own keyboard hook only while no other AutoHotkey
keyboard hook runs; with one, it falls back to SendEvent and the driver's own
InputHooks see its keys (AHK `SystemHasAnotherKeybdHook`). A hotkey thread's
SendLevel is its #InputLevel (2 for the tap-holds). Action: driver output that
is not a stand-in for a physical key goes out at SendLevel 0
(`TEXT_SENDER_SEND_LEVEL`), and observers use `I1`; the layout remap output
stays at level 2 because it is the only trace of the key its hotkey suppresses.
Every TextSender emission goes through `_TextSenderAtSendLevel`: the atomic
direct and clipboard outputs once called their primitive directly, so a
prediction accepted by the physical Tab (SC00F, #InputLevel 2) was typed at
level 2 (`test_llm_accept_injects_exact_text.ahk`,
`test-windows-llm-accept-injection.cjs`).

### project-ahk-hotif-variant-precedence

When several `#HotIf` variants of one hotkey are eligible, AutoHotkey fires the
earliest-created one, so a variant created later at run time through `Hotkey()`
can never win over a static one. The number-row tap keys
(`modules/shortcuts/tap_keys.ahk`) are static and `#Include`d before
`modules/keymap/layout.ahk`, whose digit-row emulation binds the same
scancodes; a `#HotIf` that answers false hands the key to the emulation or the
OS. `tools/test/test-tap-keys-single-source.cjs` pins that order.

### project-ahk-scan-code-hotkey-shadows-the-key-name

One `SCnnn::` hotkey makes the hook resolve that physical key by its scan code
only (hook.cpp: ChangeHookState sets `sc_takes_precedence`; LowLevelCommon then
looks up Kscm alone and lets the key through when no variant is eligible). A
hotkey named by the virtual key (`Tab::`, `^Tab`, `vk09`) never fires for the
physical key, eligible SC variant or not. The prediction's `Tab::` accept was
dead from the day `remap/tab.ahk` declared SC00F: Tab accepted only inside the
Tab tap-hold, so the neutral configuration (tap-holds off) sent it to the
application. Action: bind a key the driver already binds by scan code through
that scan code, and let variant order decide precedence
(`test_llm_tab_accepts_visible_prediction.ahk`). The registrar resolves named
keys on the VK axis, so a user chord on Tab is exposed to the same shadow.
Any SC hotkey counts, whatever its modifiers or criterion (`^SC02F`, a combo
suffix `SC138 & SC017`), and the AltGr layer declares every character key, so
a hook hotkey named by a character (`~^v`, `$^x`, one under #HotIf or a
nonzero #InputLevel) is dead on every layout: the keylogger's paste hotkey
never fired. A plain global `^!+i::` at #InputLevel 0 is a RegisterHotKey
hotkey, matched by the OS on its VK once the hook passes the key, and works.
Action: observe a chord through the HookDispatcher InputHook, which runs after
every hotkey decision (`KL_Clip_OnKeyDown`); an SC variant would compete with
the emulation's and the navigation layer's hotkeys of the key. The
hardening-c guard walks the include graph for each label's context.

### project-ahk-sendinput-puts-its-hook-first

Windows calls the most recently installed low-level keyboard hook first, and
AutoHotkey unhooks and rehooks its keyboard hook around every SendInput
(keyboard_mouse.cpp SendEventArray, `sHooksToRemoveDuringSendInput`; the rehook
calls SetWindowsHookEx again). A hook installed after AutoHotkey's, such as
`ergopti_nav_owner.dll` at boot, therefore runs first only until the driver's
next SendInput (TextSender, hotstrings). The SendEvent fallback detects only
other AutoHotkey hooks, through their mutex. Action: never let correctness
depend on the order of the AutoHotkey hook and a native hook; give each
decision to one hook outright.

### project-llm-nav-cycle-is-ahk-owned

The native owner's plan validation (NavPlanIsValid) requires one Up and one
Down cycle route that passes its key on, and changing it means rebuilding
`ergopti_nav_owner.dll` with MSVC. A first fix let the native owner cycle and
swallowed the passed arrow in AutoHotkey; once AutoHotkey's hook ran first
(`project-ahk-sendinput-puts-its-hook-first`), it swallowed every arrow before
any cycle. The `*Up`/`*Down`/`*Left`/`*Right` hotkeys in
`menu_llm/tab_accept.ahk` now cycle (`LLM_TooltipCycleActiveIdx`, whose repaint
republishes the slot to the owner) and consume the chord under
`LLM_Menu_NavCycleChordIsOwned` (#InputLevel 1, exact modifiers, owner routing
a multi-slot record). Left and Right share the chord and step of the Up and
Down routes (`LLM_NAV_CYCLE_KEYS`) and are never native routes; Shift+Tab is
`<+SC00F`/`>+SC00F` there, the most specific SC00F hotkey under that Shift, so
the hook falls back to the Tab key's other owners when its criterion refuses
(hotkey.cpp CriterionFiringIsCertain, the mNextHotkey list). The adapter parks both
native cycle routes on extended scan code zero
(`LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES`), so no hook order cycles twice or
never (`test_llm_nav_cycle_windows.ahk`, `test-windows-llm-nav-cycle.cjs`).
Action: when the DLL is next rebuilt, drop the cycle routes from its contract
together with the parked table.

### project-llm-tap-hold-tab-is-the-users-tab

The recommended AltGr taps Tab (`_shared/tap_hold/defaults.toml`), and a
tap-hold's tap runs on its key's release, so Tab is never physically down and
the old "physical Tab" policy refused it as synthetic: the Tab was typed over
every prediction. `TapHoldDispatchTap` names the key whose tap it runs
(`TapHoldTapProvenance`), and `_LLM_Accept_BareTabRefusal` accepts that Tab only
while the same tap is still dispatched, bare and in the rendered control.
Action: give a new user-key Tab producer that provenance; never pass one from a
gesture, macro, timer or text send (`test_llm_menu_tab_source_hwnd.ahk`).

### project-llm-automation-accepts

A Tab injected by another process (SendInput) reaches the Tab hotkeys and the
I1 prefix watcher, because AutoHotkey ranks unmarked input at the highest
level, but it is never `GetKeyState("Tab", "P")`; the driver cannot tell it
from its own level-2+ Tabs (remap output, roll replay), so the physical gate
must stay. External tools (the `video/` real capture) accept through the
registered message `Ergopti.LLM.AcceptPrediction.v1` instead, honoured by
`LLM_Tooltip_TryAcceptAutomation` only while the bridge is active, with the
chord's focus and held-modifier gates. Injected Ctrl combinations are not
usable either: the LCtrl tap-hold turns them into a tap (Paste). Action: add
any new external trigger as a caller of that primitive, never by relaxing the
Tab policy (`test_llm_tab_accept_policy.ahk`).

### project-llm-validation-digit-is-the-digit-row-key

The validation chord's native route was resolved by `VkKeyScanExW` of the digit
character, Shift+VK_1 on an AZERTY host, while the recommended digit-row
emulation (`direct_access_digits`) types 1 with the bare key: the chord never
matched and the digit was typed. `_LLM_Menu_NavDigitRowKey` binds digits to
VK_0..VK_9 with exactly the configured modifiers, like the macOS keycodes and
the Linux digit-row codes. The Ctrl+1..9 profile hotkeys still follow the
character. Action: keep the navigation plan layout-independent; a French
fixture must yield the same digit identities as a US one.

### project-ahk-unassigned-slot-leaves-the-key

A hotkey that runs a configurable slot must be ineligible in its `#HotIf`
while the slot holds no action. The script chords took AltGr+Enter anyway and
retyped a bare `{Enter}`, which drops the AltGr the user holds. In a
configuration without an assignment the chord did neither the action nor the
system's AltGr+Enter, and looked dead. Keyboard slots skip registration on
"none", tap keys gate on `TapKeyShouldFire`, and the script chords on
`ScriptShortcutSlotRunsAction` through `ScriptAltGrChordPlan`. Action: gate every
new slot-driven hotkey on its assignment in its criterion, never in its
callback (`test_script_chords_follow_their_slot.ahk`).

### project-ahk-probing-synthetic-input

Tests of injected input must prove provenance and destination, not merely that a
key-shaped event appeared in a hook.

## Tap-holds and synthetic modifiers

### project-ahk-computed-hotkey-identities

A hotkey name computed as `"~" . Key` has the same scan-code shadowing risk as
a literal. The registry emulation's reset loop hid five unreachable dead-key
cancel hotkeys from a literal-only source scan. Use physical scan-code identities
for all its cancel/navigation keys, and test the actual registrar boundary against
the shared registry, then drive its captured criterion and callback through a
pending accent. The source guard resolves literal-array/prefix loops only;
arbitrary computed registrations still need behavioral boundary tests.

### project-ahk-modifier-name-hotkey-shadows-scan-code

`RAlt::` (also with `~ * $`, or as `vkA5`) is its own hotkey identity, hooked on
the modifier's standard scan code. When none of its variants is eligible, AHK
does not fall back to the `SC138` variants of the same key, so the Kana-layout
AltGr tap-hold never fired (measured, v2.0.26). `$` and `~` do not form an
identity; `*` does. Action: declare modifier-key hotkeys by scan code only;
`test_modifier_hotkeys_single_identity.ahk` bans the name form, and the shared
registrar refuses a user-configured chord whose key names a modifier
(`HotkeyRegistrarKeyIsModifier`), since even an Off variant keeps the identity.

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
(Linux `NATIVE_UNDER_MODIFIER`, the macOS rules); none of their tap-hold
variants carries `*`. Their own auto-repeat then arrives under the modifier the
hold owns, matches no variant and reaches the application as that chord
(measured: Enter held as Ctrl typed Ctrl+Enter). Each owner claims its
suppressed press (`TapHoldPressIsOwned`; never a `~` pass-through press, whose
release a swallowed repeat would suppress), and every tap-hold key has a `*`
swallower gated on that claim. AHK falls back to it even when the exact hotkey
has no eligible variant, and it beats the layer's mapping of the same key only
because `nav_layer.ahk` is included last (first eligible variant wins).
A hotkey whose modifiers match exactly beats the wildcard, though: Space held
as Shift repeated the layout emulation's `+SC039` and typed « ------ », and
under a layer hold the bare repeat fell to the emulation's bare `SC039`. The
six keys therefore declare, under the same claim, the bare key and all fifteen
chords of `^ ! + #` as static labels: a static variant is created before every
`Hotkey()` one and fires first while its criterion holds (measured with F20).
Action: a module that registers an exact hotkey on a tap-hold key's scan code
needs no gate of its own, but a new native tap-hold key needs the sixteen
labels; `test_tap_hold_owned_repeat_identities.ahk` holds both.

### project-ahk-synthetic-hold-leaves-the-users-key

Windows keeps one down bit per key, so a synthetic hold's Up also lifts the
same key the user holds. A key logically and physically down before the first
owner presses it was delivered, and so will its release be; a press a hotkey
suppressed is physically down but logically up, and its Up is swallowed.
Action: the last owner skips the Up only for a key snapshotted as delivered at
acquire and still physically down (`_TH_SyntheticUserHeldKeys`); never skip on
the physical state alone, or a suppressed own press stays stuck down.

### project-ahk-lone-alt-win-release-needs-a-mask

Releasing a synthetic Alt or Win that no key followed puts classic windows in
menu mode or opens Start, and the next tap output lands there. Action: send
`TextSendMenuMask` (`{Blind}{vkff}`, the driver's `A_MenuMaskKey`) before the
release, as `_TapHoldReleaseOwnedModifier` does; Linux masks with KEY_F24.

### project-ahk-kana-altgr-is-sc138-not-ralt

On Kana-style layouts VK_RMENU has no scan code: a synthetic RAlt is a plain Alt
that enters menu mode, and the AltGr key is SC138 on another virtual key
(VK_OEM_8 on Ergopti). Action: identify AltGr through `KS_AltGrKeyName()`
(GetKeyState, KeyWait, hotkeys, the synthetic ledger), never a literal `RAlt`,
but send it by `KS_AltGrSendKey()` (`{Blind}{vkDF Down}`, as `TextPressKey`
does): Send reads a bare `SC138` as the right Alt modifier while it injects
VK_OEM_8, then presses the "missing" right Alt at the end of a SendInput and
leaves a plain Alt stuck (keyboard_mouse.cpp KeyToModifiersLR). The hook never
counts VK_OEM_8 as a modifier either, so tap-hold hotkeys without `*` still
match under it (`TapHoldKanaAltGrHeld` gates them), and a non-blind Send never
lifts it, so it modifies every character sent while it is down: send such
output through `TapHoldSendWithKeyUp` (hotstrings through
`_HSE_SendWithAltGrUp`), which lifts a held key and gives it back to whoever
held it; a raw `{SC138 Up}` ends a hold for good. A cleanup of a latched SC138
(the script AltGr chords) releases it through `TapHoldReleaseUnlessOwned`, and
only once the user has let go of it.

### project-ahk-altgr-family-follows-the-foreground-layout

The AltGr family (`_ALTGR_KANA_FIXUP`, `_ALTGR_LAYOUT_PROBE`) is not a boot
constant: with Windows' per-window input methods it follows the foreground
window's layout without a reload (`infra/altgr_family.ahk`: a foreground
WinEvent hook plus the one-second layout poll, one probe per HKL, held back
while `AltGrFamilyIsBusy`). Action: read the family through its readers at
the moment of use; a hotkey whose existence depends on the family is
registered unconditionally with the family in its live criterion
(`ScriptAltGrKanaChordIsLive`), never inside an `if` on the family
(`test_altgr_family_follows_layout.ahk` scans every registration). The
digit-row swap follows the same way, per press on the foreground layout
(`DigitRowIsSwapped`, `test_layout_digit_row_probe.ahk`). The only layout
read still fixed at load is the magic key's source key without the Ergopti
emulation; the layout poll reloads only when it differs
(`LayoutRemapSignature`).

### project-ahk-altgr-family-setting-defaults-to-the-probe

`script.alt_gr_is_kana_remap` is a parameter (`input_altering = false`,
default `"auto"`), not an activation. The neutral-configuration pass gave it
the neutral `false`, which is a forced override: every configuration that did
not name it took the standard family, the probe never decided, and on a
Kana-style layout `KS_LayoutHasAltGr()` was false, so the script chords were
dead while their menu showed them on (2026-09-30 to 2026-10-01). The tests
missed it because `_AGD_Init` substituted `"auto"` for « no override ».
Action: a setting that selects a detection mode keeps its detecting value in
an empty configuration; test the absent case with `ManifestDefaultFor`, never
a literal. When an AltGr feature is dead, read the boot `AltGrDetect` line
first: `source=override` against the layout's own verdict is now a WARNING.

### project-ahk-prefix-arms-before-physical-state

AutoHotkey decides whether a custom-combination prefix is armed while it
handles the prefix's own press (`PrefixHasEnabledSuffixes` evaluates the
suffixes' #HotIf), before it has recorded a modifier's physical state, and it
postpones a standalone variant without `~` of an armed, suppressed prefix to the
release (hook.cpp Case #1). A combination gated on its prefix's own physical
state never arms on a press, and a tap-hold on a prefix key fires on release.
Action: never gate arming on the prefix's own state; the always-eligible
`~SC138 & ~F24` anchor arms SC138 on every press and makes its standalone
hotkeys fire on the press, and every `SC01D &` combination carries `~` on the
prefix (`test_altgr_prefix_arms_on_press.ahk`, `test_altgr_takes_its_lctrl.ahk`).
That `~` never decided suppression: AHK reads SC138 as the RAlt modifier on
every layout and lets a modifier prefix's press through when no variant fires
(hook.cpp Case #1, `this_key.as_modifiersLR`), which is what keeps the
first-run wizard's AltGr native.
The anchor arms SC138 on QWERTY too, where it is a plain right Alt, so every
"SC138 & X" is reachable from a first-press RAlt+X there: a chord that must not
fire as an Alt chord (the script quit, reload and pause) also requires
`KS_LayoutHasAltGr()` (`ScriptAltGrChordIsLive`).

The anchor's arming authority is independent of a suffix's eligibility:
`IsRealAltGrPress` must query physical `SC138` on Kana, and physical `RAlt`
otherwise. A Kana family flag alone leaves suffixes eligible after release
when AHK retains a prefix latch. Rejecting in the output callback is too late
to preserve the captured native key. Keep the anchor unconditional when changing
the suffix gate; its first-press contract and the pressed/released native-query
cases guard these two separate hook decisions. Query through `KS_IsDown`,
which owns physical mode, rather than adding platform calls to the module.
Fixtures evaluating captured criteria must model the held key through
`_ALTGR_PHYSICAL_STATE_QUERY` and restore it in `finally`; the Kana family
alone never provides physical authority.

### project-ahk-altgr-fake-lctrl

On an AltGr layout every AltGr press is a fake LCtrl (scan code 0x21D, read as
SC01D and recorded as physical) then RAlt. Suppressing that RAlt in a hotkey
makes AHK send a blocked RAlt-up, which Windows answers with the fake LCtrl-up:
the SC01D prefix is cleared and every "SC138 & X" is dead for the hold. Action:
AltGr held as AltGr passes through (`altgr_criteria.ahk`), and so does a
combination that holds AltGr (Shift+AltGr...) on such a layout, its owner
pressing only the other members; a left_ctrl hold
that took the fake LCtrl is handed back when the RAlt arrives
(`TapHoldAltGrTakesItsLCtrl`); "LCtrl physically held" means
`TapHoldUserLCtrlHeld()`. Only `KS_AltGrAddsFakeLCtrl()` layouts (not Kana,
and the boot probe found an AltGr level) have the fake LCtrl: on QWERTY and
Kana a physical LCtrl held with RAlt or SC138 is the user's Ctrl, so never read
"RAlt down" as "the Ctrl is AltGr's" without that predicate. Where right Alt
is a plain Alt (`!KS_LayoutHasAltGr()`), a physical RAlt held as itself is the
Alt the application receives (`KL_Watchers_DetectShortcut`). AHK keeps a modifier the driver pressed with
`{X Down}` around later non-blind Sends, so a tap-hold's synthetic AltGr is
lifted around output on every layout (`TapHoldSendWithOwnedKeyUp`).

### project-ahk-an-undecided-key-is-decided-by-the-thread-that-interrupts-it

A tap-hold owner waiting in KeyWait is interrupted by the hotkey thread of
the next key and cannot resume before that thread returns, so a decision
that depends on the next key (a typing key rolled over it is a tap, a key
let go under it is its hold) is taken in the interrupting thread, from the
physical key states (`TapHoldRollOtherKey`), and read by the owner when it
resumes. The next key must be a hotkey for that: `tap_hold_roll_keys.ahk`
declares every text key, static, under `#HotIf TapHoldRollUndecided()`,
bare, `*` and `+` (an exact chord beats the wildcard, and the emulation's
Shift layer is exact), included before every key file so it is the
earliest-created variant. The waiting key is then sent again by scan code
with SendEvent at SendLevel 4, above every hotkey of the driver (the
emulation's Alt chords are at 3), as press and release: the hook
suppresses the release of a key whose press a hotkey suppressed. Never add
the arrows or another key the driver binds by name to that block
(`project-ahk-scan-code-hotkey-shadows-the-key-name`), nor a modifier key.
The test suites include `tap_hold_roll.ahk` (logic) and not the block, so
they hook no keyboard. Physical key state is not moved by injected events:
this path has no synthetic end-to-end test, only its logic driven through
ports in the order AutoHotkey runs the threads.

### project-ahk-worker-processes-inherit-driver-identity

AHK creates the tray icon, the main window and every load-time hotkey before a
script's first statement, so a worker re-running the entry looked like a second
driver and armed a second keyboard hook. Action: keep `#NoTrayIcon` at the
entry and reveal the icon on the driver path only; a worker suspends and
retitles itself first (`WinSetTitle` on the pure `A_ScriptHwnd` reaches the
hidden window without a DllCall).

### project-ahk-hotkey-variant-precedence

When several `HotIf` variants of one hotkey are eligible, AutoHotkey v2 fires the
one created EARLIEST, and the criterion-less (global) variant always loses
(`lib/Hotkey.htm` of the shipped help). Static `::` hotkeys are created at load,
before any `Hotkey()` call. A layer that must own keys another layer also binds
registers first: the registry layout emulation registers at boot, before
`modules/keymap/layout.ahk`. The AltGr comment in `layout.ahk` that says the
most recently defined variant wins is wrong; do not reason from it.

### project-ergopti-tables-come-from-the-keylayout

The Ergopti emulation has no hand-written character table: `layout_ergopti.ahk`
reads the shipped `static/layouts/registry` Ergopti `.keylayout` files at boot
and every layer table is derived from that data. To change what a key types,
change the `.keylayout` (through its macOS bundle), never AHK source.
Windows-only behaviour lives in the overlays and the two deviation tables of
that module; `tests/fixtures/ergopti_emulation_golden.json` freezes what the
emulation typed when the hand-written tables were retired, so an intended change
to Windows output updates that file in the same commit, and a deviation the
`.keylayout` catches up with must be deleted (a test fails while it lingers).
The compiled driver needs the registry folder in its bundle (the `required`
list of `tools/build/windows_bundle_manifest.json`), or boot fails.

## Files, configuration, and UI hosts

### project-windows-bundle-ships-only-the-manifest

The compiled exe reads its data from the zip that
`tools/build/windows_bundle_manifest.json` declares, while a source run reads the
checkout: a file an exclude group drops breaks only the shipped exe, and first
launch extracts every entry with Expand-Archive, so each shipped file costs
startup time. `test-windows-bundle-manifest.cjs` proves that every AutoHotkey
literal file name, root-anchored concatenation (`_SharedDir . "\x"`, runtime
parts as patterns), listed directory, page src/href closure and data-file path
ships. It cannot see a path assembled from data it does not model, such as a
helper joining folder names read from JSON. Action: before a new Windows read
of a file under an excluded group (`_shared/core`, `_shared/modules/**/*.js`,
`_shared/assets`, documentation, test vectors), move it out of the exclusion;
build such paths from a literal the gate can see.

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

A worker's writable candidate (cold build, refresh of the file-backed image,
upgrade copy, newest-first rebuild) is SQLite's private on-disk database with
a bounded page cache (`KLR_OpenCandidate`, `WORKER_PAGE_CACHE_KIB`), never
`:memory:`: there the whole image was the worker's memory (280 MB for a
234 MB image built from a 20 MB synthetic ledger, about 1 GB live).
`test_klr_worker_memory_bound.ahk` bounds SQLite's high-water mark on every
one of those paths. `temp_store=MEMORY` also keeps statement journals in
memory: one statement writing many rows under the newest-first build's
first-wins triggers journaled them all (63 MB for a 57 MB image), where the
ledger's one INSERT per row stays at the bound. Action: keep ledger writers at
one row per statement, and give memory fixtures that shape.

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

### project-ahk-child-inherits-every-inheritable-handle

`CreateProcessW` with `bInheritHandles` copies every inheritable handle the
driver holds at that instant, not just the STARTUPINFO streams. An AHK thread
can also be interrupted between lines: the interpreter checks its queue every
5 ms (`LONG_OPERATION_UPDATE`, v2.0.26 `defines.h`). A timer that started a
second task while the first task's capture handle was still open handed that
capture to an unrelated child. Symptom (2026-09-30, opening the versions
window): `tree-owned task N output deletion failed: (32)` after the whole job
had exited, because the leaked copy did not share delete access. Action: a
launch lists its streams in `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` and keeps them
inside Critical (`_SR_TreeCreateSuspended`). Any other inheriting launch does
the same or is audited in `tools/test/test-windows-child-handle-inheritance.cjs`.
A scanner can also hold a file its writer has just closed after job accounting
reached zero, so capture removal retries a sharing refusal for
`SR_CAPTURE_LOCK_BUDGET_MS`, then warns once and leaves the folder to the next
process's sweep; it never logs an ERROR for it.

### project-webview2-bridge-gotchas

WebView2 hosts must retain message subscriptions, wait for navigation readiness,
serialize bridge payloads with the shared adapter, reject stale generations,
and release native handlers on teardown. A page loading is not proof that its
bridge is alive.

### project-webview2-retained-host-document-fence

A retained controller keeps native queues and virtual-host subresource caches
across navigation. AHK epochs alone cannot fence a message delivered through a
new subscription on the same controller. Give each document a distinct URL,
validate message source and script destination, and tag pushed metrics envelopes
with their document epoch. Fresh navigation alone, and even network-cache
disablement, served an old same-size JavaScript edit in a native fixture; use
the checked document-cache invalidation owner before navigation. Hidden HWND
existence must also bypass thread-dependent window search settings. Retention
revokes sessions before native teardown and disposes inactive hosts at shutdown.

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

### project-gui-hidden-show-mode

AutoHotkey Gui.Show accepts one visibility mode: combining `Hide NoActivate`
selects a visible mode (`IsWindowVisible` returns 1). Use `Hide` alone when
sizing a prepared surface; keep the reveal explicit. A source assertion that
only finds `Show("Hide` cannot prove invisibility. Check the native window after
construction and after repositioning, as in the tooltip hidden-surface test.

### project-startup-probe-parse-time-isolation

Personal shortcut forwarders are parsed from both the driver's generated path
and LOCALAPPDATA before auto-execute can redirect configuration. A wrapper with
a temporary configuration alone can rewrite the live generated include. Copy
the driver code and isolate LOCALAPPDATA in the child's environment before
launch; detach any read-only junctions before removing the private fixture.

### project-native-menu-blocks-startup

An early native tray menu can suspend auto-execute and disables AHK timers until
navigation ends. Deferred construction cannot make progress behind that menu.
Retain context requests until the configured root publishes; even the first
bootstrap popup can add the user's reading interval to startup. A temporary
loading GUI was rejected by the user. Close construction timing stages before
releasing retained navigation. Menu publication and input readiness are distinct:
retain feature selections until their runtime owners exist, while lifecycle
commands retain their existing startup owner across root replacement. Restored
pause and pending lifecycle intent must take precedence over releasing feature
selections. The isolated full-startup smoke exercises both publication order and
selection admission, including inherited pause.

### project-tooltip-two-hwnd-zorder

`ShowWindow` with `SW_SHOWNOACTIVATE` reveals a window in the z-order slot it
already holds; it never raises it. The tooltip border is a second layered HWND
that must stack above the opaque content Gui, and pooled borders are older than
the content they are reused for. Place every tooltip surface explicitly at
reveal (`SetWindowPos` with `HWND_TOPMOST`, `SWP_SHOWWINDOW | SWP_NOACTIVATE`),
content first and border last. Check stacking with `GetWindow(GW_HWNDNEXT)` on
real windows, as in the tooltip border z-order test.

### project-tooltip-ring-shares-region

The tooltip border ring must be the `FrameRgn` of the same
`CreateRoundRectRgn` shape that clips the content window. A separately stroked
`RoundRect` uses its own arc rasterizer, so corner pixels can land outside the
clipped content or leave its edge unframed. `CreateRoundRectRgn` excludes one
extra right and bottom pixel, hence the `W + 1, H + 1` in the region owner.
Derive both surfaces from `_TooltipSurfaceGeometry`. The headless test harness
never loads the TOML corner radius, so tests that need arcs set it themselves.
