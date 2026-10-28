; tests/meta/platform/remap/keys/test_capsword_mouse_clobber.ahk

; ==============================================================================
; MODULE: CapsWord Mouse Clobber Meta Test
; DESCRIPTION:
; Static source guard for the capsword-mouse-clobber finding (F24).
;
; Before the fix, capsword.ahk used static ~LButton:: and ~RButton:: hotkeys
; inside a #HotIf CapsWordEnabled block to cancel CapsWord on mouse click.
; Static hotkeys bypass HookDispatcher, the sole owner of all mouse input in
; this process. Every other module that listens to mouse down events subscribes
; via HookDispatcher.Register(); having capsword register the same keys
; statically creates duplicate hooks, undefined ordering, and prevents the
; fan-out from reaching other subscribers reliably while CapsWord is active.
;
; The fix removed the static hotkeys; the listeners subscribe through
; HookDispatcher, which unit/modules/shortcuts/test_capsword_auto_off.ahk and
; test_capsword_state.ahk drive by behaviour. A static hotkey cannot be
; observed without registering it, so its absence stays a source guard.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 2/ Static hotkey absent checks =======
; ==============================================
; ==============================================

; No bare ~LButton:: label should exist in the file -- that would be a static
; hotkey registration that bypasses HookDispatcher.
_CWMC_NoStaticLButton() {
	Src := _DriverDirConcat("modules/shortcuts")
	Assert(!InStr(Src, "~LButton::"),
		"capsword.ahk must NOT contain a static ~LButton:: hotkey label -- use HookDispatcher.Register() instead")
}
Test("capsword: no static ~LButton:: hotkey label (F24 capsword-mouse-clobber)", _CWMC_NoStaticLButton)

; No bare ~RButton:: label should exist in the file.
_CWMC_NoStaticRButton() {
	Src := _DriverDirConcat("modules/shortcuts")
	Assert(!InStr(Src, "~RButton::"),
		"capsword.ahk must NOT contain a static ~RButton:: hotkey label -- use HookDispatcher.Register() instead")
}
Test("capsword: no static ~RButton:: hotkey label (F24 capsword-mouse-clobber)", _CWMC_NoStaticRButton)
