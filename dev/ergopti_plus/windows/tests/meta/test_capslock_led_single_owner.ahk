; tests/meta/test_capslock_led_single_owner.ahk

; ==============================================================================
; MODULE: CapsLock LED Single-Owner Meta Test
; DESCRIPTION:
; Static source guard for the capslock-led-multiple-owners finding.
;
; Three logical states can independently want the physical CapsLock LED lit:
; CapsWord (CapsWordEnabled), the nav layer (LayerEnabled), and a real hardware
; CapsLock toggle (AltGr+CapsLock). Before the fix, UpdateCapsLockLED OR-ed only
; CapsWord and the layer, while ToggleCapsLock drove SetCapsLockState on its own,
; so interleaving the three could leave the LED disagreeing with each logical
; state (e.g. toggling hardware CapsLock off while the nav layer is active still
; turned the LED off).
;
; The fix makes UpdateCapsLockLED the SINGLE LED owner: its condition now ORs the
; hardware toggle GetKeyState("CapsLock", "T") alongside CapsWordEnabled and
; LayerEnabled, and ToggleCapsLock routes the LED through UpdateCapsLockLED()
; instead of setting it directly.
;
; This is a meta-static test (scans source text) because both functions live in
; modules/ files (shortcuts/capsword.ahk, tap_holds/one_shot_shift.ahk) that the
; headless runner deliberately does not #Include (they register top-level
; hotkeys). If either half of the single-owner contract regresses, this fails.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_CLSO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ===================================================
; ===================================================
; ======= 2/ Single-owner contract assertions =======
; ===================================================
; ===================================================

; UpdateCapsLockLED must OR the hardware toggle into its condition so the LED is
; the union of all three logical states, not just CapsWord + layer.
_CLSO_LedConsultsHardwareToggle() {
	Src := _CLSO_ReadSource("modules/shortcuts/capsword.ahk")
	Seg := _DriverFuncBody("UpdateCapsLockLED")
	Assert(Seg != "", "UpdateCapsLockLED() declaration must exist in capsword.ahk")
	Assert(InStr(Seg, "CapsWordEnabled") > 0,
		"UpdateCapsLockLED must still consider CapsWordEnabled")
	Assert(InStr(Seg, "LayerEnabled") > 0,
		"UpdateCapsLockLED must still consider LayerEnabled")
	; The GUARANTEE is that a genuine hardware CapsLock is part of the OR, so a
	; real toggle is not overridden by CapsWord/layer state. This assertion used
	; to pin the MECHANISM — GetKeyState("CapsLock", "T") — and that mechanism
	; was the bug: it reads back the very bit SetCapsLockState writes two lines
	; below, so once CapsWord lit the LED the next evaluation saw its own output,
	; concluded the user wanted CapsLock, and re-asserted it. CapsLock then
	; survived CapsWord and everything kept typing uppercase (reproduced live).
	; The hardware intent now lives in its own variable, which satisfies the same
	; guarantee without the feedback loop.
	Assert(InStr(Seg, "_HardwareCapsLockOn") > 0,
		"UpdateCapsLockLED must OR the recorded hardware CapsLock intent into its condition, "
		. "otherwise a real CapsLock toggle desyncs the LED from CapsWord/layer state")
	HardwareTerm := "GetKeyState(" . Chr(34) . "CapsLock" . Chr(34) . ", " . Chr(34) . "T" . Chr(34) . ")"
	Assert(InStr(Seg, HardwareTerm) = 0,
		"UpdateCapsLockLED must NOT read back GetKeyState(CapsLock, T) — that is the bit it "
		. "writes, so ORing it makes the function self-latching and CapsLock outlives CapsWord")
}
Test("capsword: UpdateCapsLockLED ORs the hardware CapsLock toggle (capslock-led-multiple-owners)", _CLSO_LedConsultsHardwareToggle)

; ToggleCapsLock must delegate the LED to the single owner instead of driving it
; directly, so it can never leave the LED disagreeing with CapsWord/layer state.
_CLSO_ToggleRoutesThroughLed() {
	Src := _CLSO_ReadSource("modules/tap_holds/one_shot_shift.ahk")
	Seg := _DriverFuncBody("ToggleCapsLock")
	Assert(Seg != "", "ToggleCapsLock() declaration must exist in one_shot_shift.ahk")
	Assert(InStr(Seg, "UpdateCapsLockLED()") > 0,
		"ToggleCapsLock must route the LED through UpdateCapsLockLED() (the single LED owner) instead of setting SetCapsLockState(Off) on its own, which would desync the LED while the nav layer is active")
}
Test("one_shot_shift: ToggleCapsLock delegates LED to UpdateCapsLockLED (capslock-led-multiple-owners)", _CLSO_ToggleRoutesThroughLed)
