; tests/meta/test_lalt_rctrl_accept_suspend_guard.ahk

; ==============================================================================
; MODULE: LAlt / RCtrl Accept Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the T-W04 finding: the LLM-accept path in
; lalt.ahk and rctrl.ahk must route through TapHoldDispatchTap, whose central
; gate checks A_IsSuspended before invoking any delayed tap callback.
;
; Both tap-hold blocks reach LLM_Tooltip_FireTabOrAccept on a tap release
; that follows a KeyWait. Because the key-wait is non-blocking the AHK
; hotkey thread stays alive across a Suspend toggle, so the caller could
; fire the LLM accept callback while the driver is paused if no guard is
; present. The callback is bound and handed to the shared dispatch gate, so
; suspend and intervening-activity policy cannot drift between special paths.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Source scan helpers ======================
; =====================================================
; =====================================================

_LARSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; =====================================================
; =====================================================
; ======= 2/ Assertions ================================
; =====================================================
; =====================================================

_LARSG_LaltAcceptHasSuspendGuard() {
	Src := _LARSG_ReadSource("modules/tap_holds/lalt.ahk")
	Assert(InStr(Src, 'TapHoldDispatchTap("left_alt", LLM_Tooltip_FireTabOrAccept.Bind(""))') > 0,
		"lalt.ahk: delayed LLM accept must run through the central suspend/activity gate")
}
Test("lalt: LLM accept path has A_IsSuspended guard", _LARSG_LaltAcceptHasSuspendGuard)


_LARSG_RctrlAcceptHasSuspendGuard() {
	Src := _LARSG_ReadSource("modules/tap_holds/rctrl.ahk")
	Assert(InStr(Src, 'TapHoldDispatchTap("right_ctrl", LLM_Tooltip_FireTabOrAccept.Bind(""))') > 0,
		"rctrl.ahk: delayed LLM accept must run through the central suspend/activity gate")
}
Test("rctrl: LLM accept path has A_IsSuspended guard", _LARSG_RctrlAcceptHasSuspendGuard)
