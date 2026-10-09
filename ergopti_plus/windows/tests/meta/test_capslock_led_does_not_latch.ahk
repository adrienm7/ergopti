; tests/meta/test_capslock_led_does_not_latch.ahk

; ==============================================================================
; MODULE: CapsLock LED Self-Latch Regression Test
; DESCRIPTION:
; UpdateCapsLockLED computed the LED as
;     CapsWordEnabled or LayerEnabled or GetKeyState("CapsLock", "T")
; and then drove SetCapsLockState from that condition. The third term reads the
; exact toggle bit the first two cause the function to WRITE, so the function's
; own output became one of its inputs:
;
;   EnableCapsWord   -> CapsWordEnabled = true  -> SetCapsLockState("On")
;   DisableCapsWord  -> CapsWordEnabled = false, but GetKeyState is now TRUE
;                       (we set it) -> SetCapsLockState("On") again
;
; CapsLock therefore SURVIVED CapsWord: the user carried on typing in uppercase
; until they toggled it by hand. Reproduced live before the fix — the toggle read
; 1 after CapsWord had been disabled.
;
; The hardware intent now lives in _HardwareCapsLockOn, written only by
; ToggleCapsLock, so the union still honours a genuine CapsLock press (the
; guarantee the original guard was protecting) without the feedback loop.
;
; FEATURES & RATIONALE:
; 1. Asserts against the REAL UpdateCapsLockLED / ToggleCapsLock bodies. A
;    behavioural test is impossible here: the headless harness stubs both
;    functions (capsword.ahk registers hotkeys at load, so run_all cannot include
;    it), and driving the real ones would toggle the machine's physical CapsLock
;    mid-suite. A simulation of the OR written in this file would only test the
;    simulation, so the guard deliberately targets the source instead.
; 2. Rejects the feedback loop by CLASS — no GetKeyState of any spelling in the
;    writer — rather than pinning the one expression that shipped.
; ==============================================================================

#Requires AutoHotkey v2.0

; Source guard: the writer must not consume its own output, in any spelling.
_CLL_ConditionDoesNotReadBackTheWrittenBit() {
	Seg := _DriverFuncBody("UpdateCapsLockLED")
	Assert(Seg != "", "UpdateCapsLockLED must exist")
	Assert(InStr(Seg, "SetCapsLockState") > 0,
		"UpdateCapsLockLED must remain the single writer of the CapsLock state")
	Assert(InStr(Seg, "GetKeyState") = 0,
		"UpdateCapsLockLED must not call GetKeyState at all — it writes the CapsLock toggle, so "
		. "reading any part of that state back into its own condition re-latches the LED")
	Assert(InStr(Seg, "_HardwareCapsLockOn") > 0,
		"the hardware CapsLock intent must come from _HardwareCapsLockOn, which only "
		. "ToggleCapsLock writes")
}
Test("capsword: the LED condition never reads back the bit it writes", _CLL_ConditionDoesNotReadBackTheWrittenBit)

; ToggleCapsLock owns the intent flag; it must flip that, not the live toggle.
_CLL_ToggleFlipsTheRecordedIntent() {
	Seg := _DriverFuncBody("ToggleCapsLock")
	Assert(Seg != "", "ToggleCapsLock must exist")
	Assert(InStr(Seg, "_HardwareCapsLockOn") > 0,
		"ToggleCapsLock must flip the recorded hardware intent")
	Assert(InStr(Seg, "SetCapsLockState") = 0,
		"ToggleCapsLock must delegate the write to UpdateCapsLockLED, the single LED owner, "
		. "instead of setting the state itself")
}
Test("one_shot_shift: ToggleCapsLock flips the recorded intent, not the live toggle", _CLL_ToggleFlipsTheRecordedIntent)
