; tests/meta/test_lshift_lctrl_rshift_bounded_keywait.ahk

; ==============================================================================
; MODULE: LShift/LCtrl/RShift Bounded KeyWait Meta Test
; DESCRIPTION:
; Regression guard for the "bare zero-timeout KeyWait" finding in the simple
; tap-only tap-holds. lshift_lctrl.ahk (SC02A, SC01D) and rshift.ahk (SC036)
; used a bare, unbounded KeyWait(key) -- unlike every other tap-hold in this
; codebase, which uses the bounded "T"<duration> form. The whole-class
; regression test (test_hold_modifier_release_bounded.ahk) only recognizes
; the hold-modifier/layer "U"<timeout> release form and does not cover this
; tap-only shape, so these three sites went unnoticed.
;
; A lost key-up (focus stolen by a UAC prompt, Suspend toggled mid-press)
; wedged that single hotkey's tap/hold discrimination forever. The fix
; bounds the wait to the configured tap duration and gates the tap decision
; on the wait having actually observed a release (not a timeout).
;
; SCOPE: source introspection of modules/tap_holds/lshift_lctrl.ahk and
; modules/tap_holds/rshift.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================================
; =========================================================
; ======= 1/ Source scan helpers ============================
; =========================================================
; =========================================================

_LLRBK_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Extracts a bounded window of text around Needle (a scancode-specific
; KeyWait call), wide enough to include the tap-decision logic that follows
; it but not so wide it could bleed into a sibling hotkey block.
_LLRBK_WindowAround(Src, Needle, WindowChars := 300) {
	Pos := InStr(Src, Needle)
	if !Pos
		return ""
	return SubStr(Src, Pos, WindowChars)
}




; =========================================================
; =========================================================
; ======= 2/ No bare unbounded KeyWait remains ==============
; =========================================================
; =========================================================

_LLRBK_NoBareKeyWait() {
	Src := _DriverDirConcat("modules/tap_holds")
	Assert(Src != "", "modules/tap_holds must be readable")

	for _, Sc in ["SC02A", "SC01D", "SC036"] {
		Assert(InStr(Src, 'KeyWait("' . Sc . '")') = 0,
			"modules/tap_holds/ must not contain a bare KeyWait(" . Chr(34) . Sc . Chr(34) . ") with no timeout -- a lost key-up would wedge this hotkey's tap/hold discrimination forever")
	}
}
Test("tap_holds: lshift_lctrl/rshift no longer use a bare unbounded KeyWait (hold-keywait-tap-only-shape)", _LLRBK_NoBareKeyWait)




; =========================================================
; =========================================================
; ======= 3/ Each site is bounded and release-gated =========
; =========================================================
; =========================================================

_LLRBK_CheckBoundedAndReleaseGated(RelPath, Scancode) {
	Src := _LLRBK_ReadSource(RelPath)
	Assert(Src != "", RelPath . " must be readable")

	CallNeedle := 'KeyWait("' . Scancode . '", "T"'
	Assert(InStr(Src, CallNeedle) > 0,
		RelPath . " must call KeyWait(" . Chr(34) . Scancode . Chr(34) . ", " . Chr(34) . "T" . Chr(34) . " . TapHoldDuration(...)) -- a bare unbounded KeyWait can never time out on a lost key-up")

	Window := _LLRBK_WindowAround(Src, CallNeedle)
	Assert(InStr(Window, "Released and") > 0,
		RelPath . ": the tap decision for " . Scancode . " must gate on Released (the bounded KeyWait's return value), not on elapsed time alone -- otherwise a genuine timeout (held key or lost key-up) can be misread as a tap at the timeout boundary")
}

Test("tap_holds: lshift_lctrl.ahk SC02A (LShift) uses a bounded, release-gated KeyWait (hold-keywait-tap-only-shape)",
	() => _LLRBK_CheckBoundedAndReleaseGated("modules/tap_holds/lshift_lctrl.ahk", "SC02A"))

Test("tap_holds: lshift_lctrl.ahk SC01D (LCtrl) uses a bounded, release-gated KeyWait (hold-keywait-tap-only-shape)",
	() => _LLRBK_CheckBoundedAndReleaseGated("modules/tap_holds/lshift_lctrl.ahk", "SC01D"))

Test("tap_holds: rshift.ahk SC036 uses a bounded, release-gated KeyWait (hold-keywait-tap-only-shape)",
	() => _LLRBK_CheckBoundedAndReleaseGated("modules/tap_holds/rshift.ahk", "SC036"))
