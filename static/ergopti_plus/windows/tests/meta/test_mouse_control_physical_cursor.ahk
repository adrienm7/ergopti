; tests/meta/test_mouse_control_physical_cursor.ahk

; ==============================================================================
; MODULE: MouseControl Physical Cursor API Meta-Test
; DESCRIPTION:
; Structural regression for the DPI-correctness fix in adapters/mouse_control.ahk.
;
; Before the fix, MCSetPos() called DllCall("SetCursorPos") and MCGetPos()
; called DllCall("GetCursorPos"). Both Win32 functions operate in logical
; (DPI-scaled) coordinates when the calling process is DPI-aware, which makes
; the coordinates inconsistent on high-DPI monitors where the OS applies a
; scaling factor. The module header incorrectly described the coordinate system
; as "absolute virtual-desktop pixels" when the actual values were DPI-scaled
; logical pixels.
;
; The fix switches both calls to the Physical variants:
;   SetPhysicalCursorPos / GetPhysicalCursorPos
; These always use physical (DPI-unscaled) coordinates, making a set/get
; round-trip lossless regardless of the process DPI-awareness mode.
;
; This test inspects mouse_control.ahk source and asserts:
;   1. SetPhysicalCursorPos is used in MCSetPos.
;   2. GetPhysicalCursorPos is used in MCGetPos.
;   3. SetCursorPos is no longer called.
;   4. GetCursorPos is no longer called.
; ==============================================================================

#Requires AutoHotkey v2.0




; =============================================================
; =============================================================
; ======= 1/ Source-inspection helpers ========================
; =============================================================
; =============================================================

_MCPC_ReadSource() {
	return FileRead(A_ScriptDir . "\..\adapters\mouse_control.ahk", "UTF-8")
}




; =============================================================
; =============================================================
; ======= 2/ Assertions =======================================
; =============================================================
; =============================================================

_MCPC_SetPhysicalUsed() {
	src := _MCPC_ReadSource()
	Assert(InStr(src, "SetPhysicalCursorPos") > 0,
		"mouse_control.ahk: MCSetPos must call SetPhysicalCursorPos for DPI-correct coordinates")
}
Test("MCSetPos: uses SetPhysicalCursorPos (mouse-control-physical-cursor)", _MCPC_SetPhysicalUsed)


_MCPC_GetPhysicalUsed() {
	src := _MCPC_ReadSource()
	Assert(InStr(src, "GetPhysicalCursorPos") > 0,
		"mouse_control.ahk: MCGetPos must call GetPhysicalCursorPos for DPI-correct coordinates")
}
Test("MCGetPos: uses GetPhysicalCursorPos (mouse-control-physical-cursor)", _MCPC_GetPhysicalUsed)


_MCPC_SetLogicalGone() {
	src := _MCPC_ReadSource()
	; SetCursorPos alone (without the Physical suffix) must not be present.
	; Use negative assertion: ensure SetCursorPos only appears as part of SetPhysicalCursorPos.
	plain := StrReplace(src, "SetPhysicalCursorPos", "")
	Assert(InStr(plain, '"SetCursorPos"') = 0,
		'mouse_control.ahk: SetCursorPos (logical) must not be used — replaced by SetPhysicalCursorPos')
}
Test("MCSetPos: logical SetCursorPos not used (mouse-control-physical-cursor)", _MCPC_SetLogicalGone)


_MCPC_GetLogicalGone() {
	src := _MCPC_ReadSource()
	plain := StrReplace(src, "GetPhysicalCursorPos", "")
	Assert(InStr(plain, '"GetCursorPos"') = 0,
		'mouse_control.ahk: GetCursorPos (logical) must not be used — replaced by GetPhysicalCursorPos')
}
Test("MCGetPos: logical GetCursorPos not used (mouse-control-physical-cursor)", _MCPC_GetLogicalGone)
