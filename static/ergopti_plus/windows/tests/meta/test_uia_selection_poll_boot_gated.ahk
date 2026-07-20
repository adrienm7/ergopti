; tests/meta/test_uia_selection_poll_boot_gated.ahk

; ==============================================================================
; MODULE: UIA selection poll is boot-gated and reads Features safely
; DESCRIPTION:
; _UIA_SelectionPollTick is armed by a 500 ms timer at include position, so without
; a boot gate it fires several times during the multi-second RegisterAllHotstrings
; boot phase — each tick doing out-of-proc STA COM round-trips (GetFocusedElement +
; GetPattern + GetSelection) that pump messages and preempt the auto-execute
; registration thread. Its raw Features["shortcuts"]["wrap_text_if_selected"] read
; also sat outside the try, so a Map-shape drift in that pre-ready window would throw
; into the fatal error net (ExitApp). The tick must early-return before the driver is
; ready and read Features through .Has() guards. (F26, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_USPB_PollTickIsBootGatedAndSafe() {
	Body := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(Body != "", "_UIA_SelectionPollTick must exist in modules/keymap/layout.ahk")

	; The boot gate must precede the first COM/Features work.
	GatePos := InStr(Body, '_DriverBootPhase != "ready"')
	SuspendPos := InStr(Body, "A_IsSuspended")
	FeatPos := InStr(Body, "wrap_text_if_selected")
	Assert(GatePos > 0,
		"_UIA_SelectionPollTick must early-return before ready so no UIA COM work runs during boot")
	Assert(GatePos < SuspendPos && GatePos < FeatPos,
		"the ready-phase gate must be the first check, before the suspend/feature branches")

	; The Features read must be .Has()-guarded so a Map-shape drift cannot throw.
	Assert(InStr(Body, 'Features["shortcuts"].Has("wrap_text_if_selected")') > 0,
		"_UIA_SelectionPollTick must read Features through .Has() guards, not a bare index that can throw into the error net")
}
Test("keymap: UIA selection poll is boot-gated and reads Features via .Has()",
	_USPB_PollTickIsBootGatedAndSafe)
