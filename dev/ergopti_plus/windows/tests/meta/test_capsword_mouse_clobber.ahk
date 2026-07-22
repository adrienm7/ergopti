; tests/meta/test_capsword_mouse_clobber.ahk

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
; The fix removes the static hotkeys and instead calls:
;   HookDispatcher.Register(HookDispatcherConst.EVT_MS_LDOWN, ...)
;   HookDispatcher.Register(HookDispatcherConst.EVT_MS_RDOWN, ...)
; when CapsWord activates, and the matching Unregister() calls when it
; deactivates (both in ToggleCapsWord and DisableCapsWord).
;
; This is a meta-static test (scans source text) because capsword.ahk contains
; top-level #HotIf / hotkey blocks that the headless runner cannot #Include.
; If the static hotkeys are reintroduced or the dynamic registration is removed,
; this test fails immediately.
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





; ================================================
; ================================================
; ======= 3/ Dynamic registration present  =======
; ================================================
; ================================================

; HookDispatcher.Register must be called with an LButton event type constant so
; the module subscribes to left-click down through the unified fan-out.
_CWMC_DynamicLButtonPresent() {
	Src := _DriverDirConcat("modules/shortcuts")
	; The registration must reference the EVT_MS_LDOWN constant
	Assert(InStr(Src, "EVT_MS_LDOWN"),
		"capsword.ahk must call HookDispatcher.Register with EVT_MS_LDOWN to cancel CapsWord on left click")
}
Test("capsword: dynamic HookDispatcher.Register for EVT_MS_LDOWN present (F24 capsword-mouse-clobber)", _CWMC_DynamicLButtonPresent)

; Same check for right-click.
_CWMC_DynamicRButtonPresent() {
	Src := _DriverDirConcat("modules/shortcuts")
	Assert(InStr(Src, "EVT_MS_RDOWN"),
		"capsword.ahk must call HookDispatcher.Register with EVT_MS_RDOWN to cancel CapsWord on right click")
}
Test("capsword: dynamic HookDispatcher.Register for EVT_MS_RDOWN present (F24 capsword-mouse-clobber)", _CWMC_DynamicRButtonPresent)

; The matching Unregister calls must also be present so the listener is torn
; down when CapsWord deactivates and does not linger as a stale subscriber.
_CWMC_UnregisterPresent() {
	Src := _DriverDirConcat("modules/shortcuts")
	Assert(InStr(Src, "HookDispatcher.Unregister"),
		"capsword.ahk must call HookDispatcher.Unregister to remove the mouse listener when CapsWord deactivates")
}
Test("capsword: HookDispatcher.Unregister call present (F24 capsword-mouse-clobber)", _CWMC_UnregisterPresent)