# Windows 107 native-HKL descriptor tranche

Prepared outside the repository against source `5e622935b7618bb9f8e3e1508141773046ed2134`.
The two owned changes append production observation APIs and five cases to an
already registered native test module. All previous production and test bytes
remain exact prefixes, including the current KLE symbols implementation.

`KS_NativeKeyLevel` preserves the native signed count, text and text/dead/none
kind. It delegates native reads to the existing byte-unchanged
`KS_KeyTextNoStateChange`, whose `ToUnicodeEx` call uses flag `0x4`; it never
flushes, arms or clears a dead state. Native dead previews do not invent KLE
action/state names. `KS_NativeNumberRowLevels` reads both levels of all ten
positions using the existing scan-code registry and each explicit HKL's
scan-code-to-VK mapping. CapsLock is passed explicitly at each observation.
Invalid input, malformed observations and refused/throwing ports return zero
without returning exception details or a partial row. Results are detached.

These are observations, not source/currentness or output receipts. They neither
change desired/effective modes nor add native symbols capability. A caller cannot
pass the observation to `NumberRowPolicyReady` and receive permission to emit.
The native forced-digit/symbol owner remains unimplemented; TODO 107 remains
partial.

## Verification

- Private source-envelope controls passed. The predecessor and six source
  omissions are expected red controls, not executed AHK behavior.
- The unchanged AHK v2 syntax scanner passed on the three captured AHK files.
- Both changed AHK sources retain UTF-8 BOM and LF. Private Python controls pass
  Ruff. The independent ten-key corpus bytes were copied unchanged and never
  regenerated.
- Five new cases are registered by the existing `run_all.ahk` include: actual
  French/US levels against the frozen corpus; actual US CapsLock/French native
  circumflex status; actual adapter port transport; strict refusals; detached
  signed/unmapped/multi-unit descriptors. These five cases and the existing
  native suite are **unexecuted locally**. No Wine or actual Windows runtime is
  installed here. No native E2E, packaging, installation or hardware claim is
  made. Parent Windows CI must execute them before admitting the tranche.

## Exact subsequent software contract

Current menu admission captures `_LayoutPollRetry`, foreground HKL, source model,
generation, lifecycle, CapsLock and config source, but the native number-row
delivery callbacks do not join that receipt with physical press provenance and
native output retirement. `_DigitRowDown`/`_DigitRowUp` send digit events directly;
`_DigitRowSwapSend` delegates native symbols to `_DigitShiftSend`'s Unicode text
emission. That path cannot represent native dead-key composition safely.

A forced native owner must capture an exact physical source/press, destination
HKL and config/model epoch, recheck master/pause/Nav/Shift/AltGr/Caps immediately
before delivery, and acquire the existing native modifier/output owner. Native
VK/SC delivery must retain the original native dead-state machine rather than
send the preview text. Exact emitted down/up ownership, repeats and physical
release must retire with an acknowledgement; false/throw/changed-source leaves
owned debt and forbids successor delivery. Tests must retain the frozen ten-key
vectors and prove these boundaries through actual native source/output ports.
This requires a separately coordinated native input/output owner lease; no G7
hook, shared schema, locale or source ownership was expanded here.
