; tests/meta/test_uia_selection_background_poll.ahk

; ==============================================================================
; MODULE: UIA Selection Background Poll Meta Test
; DESCRIPTION:
; Static source guard for the uia-selection-blocks-keyboard-thread finding.
;
; UIA selection queries (COM round-trips) must not run on the synchronous
; keyboard hot-path (GetUIASelection called from _OnChar/WrapTextIfSelected).
; They must be moved to a background polling timer, with GetUIASelection()
; merely returning the cached value.
;
; The fix introduces _UIA_SelectionPollTick() and _UIA_SelectionCache.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_USBP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Background poll assertion ==============
; ===================================================
; ===================================================

_USBP_SelectionIsPolledInBackground() {
	Src := _USBP_ReadSource("modules/keymap/layout.ahk")
	
	; 1. Verify background tick exists and does the heavy lifting.
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(TickBody != "", "_UIA_SelectionPollTick must exist in modules/keymap/layout.ahk")
	Assert(InStr(TickBody, "UIA.GetFocusedElement()") > 0,
		"_UIA_SelectionPollTick must perform the UIA query (uia-selection-blocks-keyboard-thread)")
	Assert(InStr(TickBody, "_UIA_SelectionCache :=") > 0,
		"_UIA_SelectionPollTick must update the _UIA_SelectionCache")
	
	; 2. Verify GetUIASelection is now just a cache reader.
	GetterBody := _DriverFuncBody("GetUIASelection")
	Assert(GetterBody != "", "GetUIASelection must exist in modules/keymap/layout.ahk")
	Assert(InStr(GetterBody, "Snapshot := _UIA_SelectionCache") > 0,
		"GetUIASelection must inspect the cached snapshot only (uia-selection-blocks-keyboard-thread)")
	Assert(InStr(GetterBody, "UIA.GetFocusedElement()") == 0,
		"GetUIASelection must NOT call UIA directly on the keyboard path (uia-selection-blocks-keyboard-thread)")

	; 3. Verify timer is armed.
	Assert(InStr(Src, "SetTimer(_UIA_SelectionPollTimer, 500)") > 0,
		"UIA selection poll timer must be armed with a periodic interval")
}
Test("layout: UIA selection is polled in background (uia-selection-blocks-keyboard-thread)", _USBP_SelectionIsPolledInBackground)

; The poll tick runs on a SetTimer, which bypasses native Suspend, and does a
; 3-hop UIA COM round-trip + an unbounded GetText(-1). It must early-return while
; paused (« pause = tout éteint ») and skip the COM work when its only consumer
; (WrapTextIfSelected, gated on wrap_text_if_selected) is disabled.
_USBP_PollTickSuspendAndFeatureGated() {
	Src := _USBP_ReadSource("modules/keymap/layout.ahk")
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(TickBody != "", "_UIA_SelectionPollTick must exist in modules/keymap/layout.ahk")
	Assert(InStr(TickBody, "A_IsSuspended") > 0,
		"_UIA_SelectionPollTick must early-return on A_IsSuspended — SetTimer bypasses native Suspend, so the synchronous UIA COM poll would keep firing on the keyboard thread while paused (uia-poll-bypasses-suspend)")
	Assert(InStr(TickBody, "wrap_text_if_selected") > 0,
		"_UIA_SelectionPollTick must skip the COM round-trip when wrap_text_if_selected (its only consumer) is disabled, so non-users never pay the per-tick cost or the large-selection stall risk (uia-poll-bypasses-suspend)")
}
Test("layout: UIA selection poll is gated by suspend + the wrap feature flag (uia-poll-bypasses-suspend)", _USBP_PollTickSuspendAndFeatureGated)

; A timer still runs on AHK's sole message thread. It must not start a COM call
; during active typing, and it must never request an unbounded TextPattern range.
_USBP_PollTickIsIdleGatedAndBounded() {
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(InStr(TickBody, "A_TimeIdlePhysical < UIA_SELECTION_IDLE_REQUIRED_MS") > 0,
		"_UIA_SelectionPollTick must skip new UIA COM work while physical input is active, so its timer cannot contend with keyboard dispatch")
	Assert(InStr(TickBody, "GetText(UIA_SELECTION_MAX_TEXT_CHARS)") > 0,
		"_UIA_SelectionPollTick must cap TextPattern.GetText so a document-sized selection cannot monopolise the AHK thread")
	Assert(InStr(TickBody, "GetText(-1)") = 0,
		"_UIA_SelectionPollTick must not request an unbounded UIA text range on the driver thread")
}
Test("layout: UIA selection poll waits for idle input and caps retrieved text (uia-selection-poll-budget)", _USBP_PollTickIsIdleGatedAndBounded)

_USBP_SelectionCacheInitialized() {
	Src := _USBP_ReadSource("modules/keymap/layout.ahk")
	; An unset global causes return _UIA_SelectionCache inside GetUIASelection
	; to throw "variable has not been assigned" on the first WrapTextIfSelected
	; call, before the poll timer has fired even once
	Assert(InStr(Src, "global _UIA_SelectionCache :=") > 0,
		"layout.ahk must initialize _UIA_SelectionCache at declaration — an unset global causes GetUIASelection to throw on first call before the poll timer fires (uia-selection-cache-unassigned 2026-06-16)")
}
Test("layout: _UIA_SelectionCache is initialized at declaration, not left unset (uia-selection-cache-unassigned)", _USBP_SelectionCacheInitialized)
