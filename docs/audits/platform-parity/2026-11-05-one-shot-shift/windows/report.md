# Windows single-use Shift: capture, consumption and control replay

Audited source: `9c565c88c9a1366a2e9b18c1b9d2868509510975`, November 5, 2026.

This scope follows the Windows `one_shot_shift` action from its public catalogue
and physical producers through suppressive scalar capture, transformation,
control replay and teardown. The generic sticky-modifier implementation is a
comparison boundary, not an audit of every sticky modifier. No production or
registered test code was changed.

All findings and positive controls below derive from authenticated executable
source. **No AutoHotkey code, keyboard hook, native modifier state or receiving
editor ran in this Linux environment.** The Python probe checks file identity
and lexical relationships; it does not emulate AHK. A successful source probe
is not a runtime or Windows receiving pass.

## Confirmed source-derived finding

### OSW-001 — Named-control replay does not retain original modifier attribution

Severity: medium. Confidence: high for the code path. Guarantee G2 and named
property `modified_control_identity`; native admission/receiving remains qualified.

A precise source-derived reproduction is:

1. Use a blank scratch editor. Keep CapsWord off; disable hotstrings and Enter
   remaps so another feature cannot claim the control. Configure an independent
   action/gesture to invoke `one_shot_shift` and finish its carrier modifiers.
   The shared catalogue and Windows gesture table expose this action directly.
2. Arm that capture. Press and hold real LCtrl, then Enter before the ordinary
   two-second capture timeout. Independently test real Shift+Enter and
   Ctrl+Backspace. Keep the modifier held while the captured control is replayed.
3. Conditional on the native hook completing as its explicitly configured named
   control, `_SIHO_ReadScalar` publishes `Kind="control"`, `Name="Enter"` (or
   BackSpace/Delete) and no captured modifier information.
4. `OneShotShift` calls `SendNewResult("{" . Capture.Name . "}", False, False)`.
   Its default fourth argument is `Atomic=false`, and the nonliteral production
   branch uses ordinary `SendEvent(Text)` without `{Blind}` or an explicit
   modifier chord.
5. The local sender contract explicitly documents that ordinary Send lifts
   externally held modifiers; `_TapHoldKeyTapModifiers` uses `Blind` precisely
   to prevent that in native tap replay. Here the requested replay is a bare
   Enter, not the original Ctrl/Shift+Enter. The same statement applies to
   the other captured named controls.

No actual physical Ctrl/Shift completion, suppression count, duplicate event,
chat submission or editor output is claimed. The confirmed source property is
loss of modifier attribution in the requested replay after a qualifying native
completion; genuine AHK receiving is still needed to measure the complete effect.

The relevant exact owners are:

- `platform/remap/one_shot_shift.ahk::OneShotShift`: explicit named completion,
  plain-control dispatch and no modifier snapshot/pass-through argument.
- `infra/suppressive_inputhook_ownership.ahk::_SIHO_ReadScalar`: the result has
  Kind/Text/Name/Reason, without captured chord attribution.
- `infra/hotstrings/hotstring_send.ahk::SendNewResult`: defaults to non-atomic
  normal SendEvent for this `OnlyText=false` call.
- `platform/remap/constants.ahk::_TapHoldKeyTapModifiers` and its adjacent
  `TapHoldAnyModifierHeld` contract: existing native-key producers preserve
  external modifiers explicitly because ordinary Send lifts them.

The already authenticated `modules/keymap/layout.ahk::DeadKey` has a sibling
control branch that reads the same decoder and calls ordinary
`Send("{" . Capture.Name . "}")`. It belongs to the same capture/replay root,
not a second new finding or an expansion into the full dead-key module.

Why the existing tests miss it: the end-key meta guard only authenticates the
explicit BackSpace/Enter/Delete list and the call order. The native scalar
fixture explicitly requires every physical modifier released. Settlement and
rearm fixtures use unmodified named controls or emitter records. None of these
asserts the original control chord at a real target while Ctrl/Shift is held.
Those genuine AHK fixtures were inspected, not executed here.

Regression direction: through the real capture and public sender, retain the
original completing control's modifier identity and final destination/admission.
Compare unmodified controls and LCtrl/Shift/Alt/Win-modified variants, with the
modifier held and released between capture and dispatch, and test native refusal
or pause/rearm. Simply adding `{Blind}` preserves live modifiers, which may
already differ from those at the captured press; it is not by itself proof of
original-chord preservation. Apply the same class requirement to the sibling
DeadKey control branch. Preserve exactly-once control delivery and the existing
scalar/suspend ownership guards; do not infer native suppression from source.

## Positive contracts and intentional or unresolved variants

- **Character transform:** the Windows owner captures a complete scalar rather
  than holding Shift down for every subsequent key. It titlecases normal text
  with AHK `Format("{:T}", Scalar)` and uses the shared seven-result punctuation/
  space table. The chosen magic key gets `J` before an ordinary table result.
  `%` becomes ` %`, space becomes `-`; those outputs can themselves contain
  a checked CapsWord delimiter. Literal output has the existing observer.
- **Action alias:** shared declarations expose `one_shot_shift` on Windows and
  identify macOS `sticky_shift` as its equivalent. A different ID or producer
  does not prove missing functionality. Actual Lua/native behavior belongs to
  the other reviewers.
- **Producer distinction:** the dedicated physical LAlt route begins capture on
  key-down. After that capture completes it can hold native LShift until the
  physical LAlt release; cleanup uses a bounded wait and finally. The dedicated
  RCtrl route waits its tap deadline and invokes capture only for the tap;
  the long press instead holds Shift. Generic catalogue invocation has neither
  of these physical key lifetimes. These are explicit existing local mechanics;
  a common product decision for every origin is not inferred.
- **CapsWord:** `OneShotShift` itself does not call DisableCapsWord. That call in
  the same file belongs to `ToggleCapsLock`. File-level search would give a
  wrong state-machine conclusion. Physical CapsWord hotkeys and remapped output
  still have native priority/receiving qualifications.
- **Held real Shift:** titlecasing uses the captured text, not an assumed lower
  level from a physical key. Actual layout/IME/native modifier attribution was
  not executed. Full Unicode titlecase output cannot be equated with a shared
  generated Lua Unicode mapping merely from the action alias.
- **Timeout:** constants load `ONE_SHOT_SHIFT_TIMEOUT_SEC` from the shared
  Timings entry `tap_hold.one_shot_shift_timeout_ms=2000`. A nonpositive/unset
  constant falls back to 2 s. No Windows user-menu route that turns this into an
  infinite wait was established; macOS timeout configuration must not be
  silently attributed to this owner.
- **Re-invocation:** the exclusive registry refuses a second capture while an
  incumbent is live. Refusal happens before setting the logical enable bit,
  so it preserves both enabled and explicitly disabled incumbents. This is
  intentional capture admission, not a universal toggle/re-arm guarantee.
- **Chord cancellation:** `OneShotShiftFix` sets the enable bit false without
  cancelling the native capture. Explicit LAlt/RCtrl and configured key-pair
  paths invoke it. A subsequent admitted scalar can be replayed unchanged.
  A broader native Ctrl-letter spending rule is not established here.
- **Suspend:** the native suspended bit is checked before capture and inside
  exact-token publication; teardown stops registered suppressive owners and
  clears the logical bit. Stop/unregister acknowledgments reject stale owners
  even if a pause and resume occur before the older Wait unwinds. A failed
  native Stop keeps cleanup ownership, preventing an optimistic output commit.

## Refutations and explicit gaps

The stale true `OneShotShiftEnabled` value after ordinary completion is not
counted as a separate defect: current outside functional consumers do not turn
it into another pending capture. The registry, not that bit, owns native capture.
A broad claim that this makes every following key uppercase is therefore false.

Tab/Escape are **not** counted as proved missing controls. `_SIHO_ScalarEndKeys`
contains BMP control units, while the explicit named list contains only
BackSpace/Enter/Delete. Native `EndKey` representation under E/C and visibility
needs actual AHK observation before deciding whether Tab/Escape cancel, replay
or pass through. Nor is duplicate-control delivery inferred from hook options.

The existing native rearm fixture covers real producer code with a passive hook
constructor port; settlement covers a successor inserted while Stop is pending.
These do not prove all reentry after a successful retirement and before the
subsequent replay. A possible post-retirement generation window remains a
hypothesis, not another finding.

Likewise, native hook completion precedes script replay. No actual editor test
of rapid `abc` under a delayed script thread was executed here. The evidence
does not establish either a measured reordering or a proof of preserved receiver
order. Native scalar fixtures and emitter logs alone cannot settle that question.

The immutable scalar EndChars string is prewarmed/cached, but the native hook
constructor's allocation cost is not measured by reading its source. This
pass makes no G4 latency, native constructor timing or long-duration memory claim.

## Validation and reproducibility

The portable `source-contract.py` authenticates 31 named files against both the
pinned Git objects and current bytes. Its 40 qualified lexical checks require
nonempty uniquely identified bodies before absence checks. Source-reader
controls accept a body with literal/comment braces and reject missing, empty,
unclosed and duplicate declarations. This is not an AHK parser or emulator.

Two final bounded source sweeps, after the last confirmed root, retain exact
commands, program hashes and observations in `dry-sweeps.json`. They report no
additional independent root in the bounded source scope. Runtime cases remain 0;
repeated lexical checks are not additional unique coverage.

`coverage.json` distinguishes these 40 contracts and seven unverified/native
qualification rows. The false-green scanner is within its unchanged baseline
(0 versus 0); that mechanical scan cannot establish semantic test adequacy.

```sh
python3 source-contract.py /path/to/ergopti --sweep independent
```

Original source receipts remain portable to another checkout with the pinned
commit available. Native input, target applications, custom layouts/IME,
control-modifier receiving, post-retirement scheduling and desktop latency
remain unexecuted. No logs were attributed to a live Windows driver.
