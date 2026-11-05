# Windows CapsWord: action identity and lifecycle audit

Audited commit: `f2a7dba5fc580aad61e6a0ed16ede84406aed2b0`.

This bounded review follows Windows CapsWord from real bindings, tap-hold
admission and the shared action catalogue to its state owner, native CapsLock
write, delimiter observers, configuration publication and lifecycle. Its two
findings are derived from authenticated executable source. **No AutoHotkey
code, keyboard hook, CapsLock LED, native editor or wall-clock timer ran.**
Python checks source relationships; it does not emulate AutoHotkey or certify
that a native receiving application accepted an event.

## Confirmed source-derived findings

### CW-W001 — The physical tap carrier replaces the real emitted delimiter identity

Severity: medium. Confidence: high. Guarantee: G2, qualified as a source-derived
missing automatic-end behavior. No native reproduction is claimed.

Reproduction A, automatic end without a delimiter:

1. In `config.toml`, set `[shortcuts.caps_word] idle_timeout_seconds = 0` and
   `terminators = ["tab"]`. Set every Windows pointer kind false in
   `[shortcuts.caps_word.pointer]`: `pointer_motion`, `left_click`, `right_click`,
   `middle_click`, `other_buttons`. Keep AI disabled/no prediction tooltip,
   navigation layer off and every other modifier released.
2. In `tap_hold.toml`, set `[tap_hold] inherit_defaults = false`, then
   `[tap_hold.keys.tab] tap_action = "backspace"` without a hold. Backspace is a
   supported real shared catalogue action, not an invented action name.
3. Activate CapsWord through a supported independent `caps_word` binding, type
   two letters, then press the remapped Tab alone.
4. The generic tap-only SC00F variant offers acceptance, observes the empty
   tooltip and declines it, then calls `_TabDispatch`. The source deactivates
   CapsWord for the physical `tab` id **before emitting Backspace**. No checked
   delimiter was typed; the next letter loses CapsWord. Native sending/case was
   not executed. The CapsWord module defines no SC00F native delimiter hotkey.

Reproduction B, a checked delimiter without automatic end:

1. Keep idle and pointer ends disabled, select only `terminators = ["enter"]`.
2. Configure `[tap_hold.keys.caps_lock] tap_action = "enter"` without a hold.
   Activate CapsWord using another supported binding, press CapsLock alone.
3. Its tap-only SC03A handler suppresses physical CapsLock and emits the real
   Enter action. The physical `caps_lock` id is not a delimiter; SendLevel0
   hides the actual Enter from the I1 observer and no CapsWord synthetic-key
   publication follows. CapsWord remains enabled. `_CapsLockInvokeTap` calls
   genuine ToggleCapsLock only for caps_lock/toggle_capslock actions, not Enter.
   There is no unconditional CapsWord deactivation in this producer.
4. Actual native submission and subsequent letter case remain unexecuted. The
   native CapsWord hotkeys SC039/SC01C do not intercept this SC03A carrier.

Root cause and exact path:

- `platform/remap/tab.ahk`'s generic tap-only variant calls `_TabDispatch`,
  then `_TapHoldFireAction("tab")` after AI acceptance declines; the checked
  physical tab id deactivates CapsWord before its Backspace callback.
- `platform/remap/capslock.ahk`'s tap-only variant calls `_CapsLockDispatch`,
  then `TapHoldDispatchTap("caps_lock", _CapsLockInvokeTap)`.
- `platform/remap/constants.ahk::TapHoldDispatchTap` evaluates
  `_TapHoldTapEndsCapsWord(KeyId)` before invoking the configured callback.
  That helper asks `CapsWordAutoOffIsTerminatorKey(KeyId)` and
  `CapsWordAutoOffEndsOnNativeKey(KeyId)`. The physical id `caps_lock` is not
  a delimiter, even though the admitted action is `enter`.
- `_CapsLockInvokeTap` routes this action to `_TapHoldInvokeConfiguredAction`,
  which emits the actual `Action.Key/Action.Mods` through `TapHoldEmitKeyTap`
  and `TextPressKey`.
- `adapters/text_sender.ahk::_TextSenderSendInput` uses SendLevel0 and the
  shared dispatcher is `V L0 I1`. Its synthetic buffer effect owner contains
  no CapsWord output publication. The emitted Enter is therefore not caught
  later by either the real typed-character observer or the literal-output one.

Why existing checks do not expose it: the actual unit regression
`test_capsword_taphold_unlatch.ahk::_CTU_DispatchWith` supplies the marker callback
`(*) => (Ran := true)`. It checks physical Space/Enter/Tab ids but never emits a
remapped action. Its CapsLock non-terminator control omits the configuration
that makes that carrier actually type Enter. These tests were reviewed, not
executed in this environment.

An additional source-path asymmetry exists for Space configured as Backspace:
the generic dispatcher would deactivate based on `KeyId=space` before its real
Backspace callback. However the CapsWord SC039 native hotkey can compete with
the Space tap-hold variant. The existing test's prose says later-defined wins;
its actual assertion only verifies include order and does not execute native
HotIf priority. The physical Space reproduction is **not retained as confirmed**
until the real native priority is established. This uncertainty does not apply
to the CapsLock→Enter path above.

Regression direction: execute the public Tab and CapsLock tap-only producers, real action
resolver and state owner with passive native send/LED ports. Compare native
Tab/Backspace, Tab→Backspace and CapsLock→Enter/Space, held modifiers, checked delimiter
and send refusal. Assert that qualifying acknowledged action output ends
CapsWord. A rejected tap must not publish a delimiter. Keep native Space's
HotIf competition as an independently qualified receiving/priority control,
rather than silently using the direct callable dispatcher as native proof.

### CW-W002 — AltGr's CapsWord binding cannot toggle an active session off

Severity: medium. Confidence: high. Guarantee: G2. Source-derived control flow;
no physical AltGr or AutoHotkey callback executed.

Reproduction:

1. Set idle timeout 0, `terminators = []` and every pointer setting false.
2. In `tap_hold.toml`, use `[tap_hold] inherit_defaults = false` and
   `[tap_hold.keys.alt_gr] tap_action = "caps_word"`, `hold_modifier = "shift"`.
3. Make two separate short isolated AltGr taps, releasing all keys between them.
   Each must pass the actual existing hold/tap and prior-key-self admissions.
4. The first admitted action turns CapsWord on. The second first clears it in
   `_AltGrHandleHold`, then the configured `caps_word` action toggles it on
   again. The same valid binding cannot perform its documented toggle-off.
   This sequence is a deduction from the actual statement order, not an
   AutoHotkey state-machine simulation or measured native event trace.

Root cause: `platform/remap/altgr.ahk::_AltGrHandleHold` calls
`DisableCapsWord()` unconditionally inside its accepted isolated-tap branch,
before `AltGrTapHoldDispatchV2` invokes `_TapHoldFireAction("alt_gr")`.
The real `GESTURE_ACTIONS["caps_word"].Fn` calls `ToggleCapsWord`, whose state
owner flips the current Boolean. A generic dispatch under a non-delimiter
`alt_gr` id does not restore the original on/off intent. The unconditional
pre-clear also ends CapsWord for AltGr→Backspace even with every automatic end
setting disabled; this is a sibling symptom, not a third finding.

Why silent: both operations are individually accepted and the final LED is on.
There is no sender failure or malformed configuration to log. The direct state
unit checks correctly prove that calling `CapsWordActivationToggle` twice turns
it off, but they bypass the AltGr producer's unconditional pre-clear.

Regression direction: drive `_AltGrHandleHold` with the real configured action
lookup and state owner, recording hold/send/LED ports. Two admitted taps must
perform off→on→off. Cover an action that really types a checked delimiter,
Backspace, a blocked/refused tap, and the plain/native action. Do not weaken
AltGr's pass-through/fake-LCtrl ownership or its prior-key-self guard.

## Parity, documented behavior and refutations

- The shared manifest specifies matching the **character actually typed**,
  regardless of key, layer or dead key, and honoring its selected checkbox.
  No emitted-key delimiter exception for these remapped taps is declared.
- The `caps_word` action's macOS equivalent is `capsword`; the spelling differs
  deliberately. Windows/Linux share the former action id. Different spelling
  does not imply missing functionality.
- Windows deliberately stages stored auto-off changes for the **next** CapsWord
  activation. `CapsWordAutoOffStore` persists successfully before publishing
  `Configured/Values`; the active `Armed` policy and its timers remain intact.
  This is an explicitly documented implementation snapshot, not evidence that
  newly saved policy has already affected the current activation. Cross-OS live
  update intent remains a product comparison for the shared review.
- The authoritative default is 10 seconds and eight delimiters. The adapter's
  old header saying “no delay” is stale prose, not the effective configuration.
- Windows has five pointer kinds. Wheel directions map to `pointer_motion`.
  A separate touchpad-gesture checkbox is explicitly absent on Windows because
  the OS retains those gestures; the manifest supplies the reason. This is a
  native-observation constraint, not a missing complete pointer feature.
- Existing native CapsLock is recorded before the write-owning includes.
  `CapsWordLedWanted` ORs genuine intent with CapsWord, and ToggleCapsLock
  changes the recorded intent rather than reading its own LED output back.
  Ending CapsWord while genuine intent is on deliberately leaves CapsLock on.
- Every key-down, including an isolated modifier, restarts the Windows idle
  timer while enabled; its listener has no modifier filter. Zero arms no idle
  timer. Windows uses its timer adapter rather than subtracting a 32-bit tick
  here, so an invented CapsWord tick-rollover calculation is not a finding.
- Old callbacks cannot borrow a replacement activation. Bound callbacks carry
  exact generations; disarm detaches state before cleanup/logging; the ending
  callback rechecks retired generation after potentially yielding logging.
  Existing real-AHK timer-interruption tests encode these controls, but were
  not executed here. Native Space's send/wait uses the same original generation.
- A fresh activation records a fresh current pointer position. There is no
  inherited pointer throttle in the Windows owner. Unchanged coordinates do
  not deactivate; any changed coordinate does when selected.
- Suspend gates the central dispatcher and explicitly calls DisableCapsWord
  through the required lifecycle step. Fatal cleanup clears the state and
  synchronizes the LED; inactive auto-off callbacks retire their listeners.

## Conditional observations and explicit gaps

The successful shutdown path stops the dispatcher but does not explicitly call
CapsWordDeactivate/DisableCapsWord or SetCapsLockState. A reload successor seeds
genuine intent from the native toggle. Whether this strands the old temporary
CapsLock depends on AutoHotkey/native exit restoration semantics, not established
in this environment. This remains a **conditional receiving gap**, not a third
confirmed finding. The absence is read at the actual shutdown owner, not inferred
from an unrelated lifecycle directory.

TextSend's direct mode reports a delimiter after a successful sender verdict;
its clipboard/native modes report when queued. A later admission refusal can
therefore have no matching actual text. The queuing behavior is explicit in the
source, but no common CapsWord policy for pending/refused output was established
and no native refusal/receiving case was executed. This is separately documented
policy/transaction debt, not counted as a confirmed defect here.

The precise ordering of a same-activation key-down versus an already-entered idle
callback needs a real AHK scheduler fixture. Replacement-activation tests do not
by themselves settle this finer boundary. It is not promoted to a source-derived
race claim without a reproducible admitted interruption.

No real IME, dead-key layout, keypad Enter receiving, pointer device, lock LED,
native text service, pause/quit process or user application was exercised. Code
mapping of multi-scalar payloads and all pointer kinds is distinct from those
receiving qualifications. No performance/G4 latency measurement or long-duration
memory-growth measurement is claimed.

## Evidence and reproducibility

`source-contract.py <repository>` authenticates 32 exact files against the source
pin and checks 39 executable-source relationships with positive controls. It
requires actual nonempty declarations and matched bodies before absence checks.
Its source masking handles AHK strings and line comments; it is a deliberately
bounded source reader, not a full AHK parser. `source-contract.json` records the
real source receipts and checks. Root may replay it against the integrated tree
while those claimed files remain byte-identical.

The mechanical false-green scan returned baseline 0 versus 0; that does not make
the behavioral test coverage complete. `coverage.json` retains each inspected
aspect and its actual evidence basis. `dry-A.json` and `dry-B.json` are the final
two bounded lexical/control sweeps after the last confirmed root cause. Their
matching outcomes are not additional independent runtime tests.
