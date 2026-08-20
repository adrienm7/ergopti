; tests/meta/test_uia_selection_background_poll.ahk

; ==============================================================================
; MODULE: UIA Selection Background Poll Meta Test
; DESCRIPTION:
; Static source guard for the uia-selection-blocks-keyboard-thread finding.
;
; UIA selection queries (COM round-trips) must not run on the synchronous
; keyboard hot-path (GetUIASelection called from _OnChar/WrapTextIfSelected).
; A SetTimer still runs on the keyboard thread, so "background timer" is not
; sufficient. UIA must run in a killable detached process, with the timer posting
; one non-blocking request and GetUIASelection() merely reading the cache.
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
	
	; 1. The resident tick may dispatch, but must never enter COM itself.
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(TickBody != "", "_UIA_SelectionPollTick must exist in modules/keymap/layout.ahk")
	Assert(InStr(TickBody, "UIASW_Request(") > 0,
		"_UIA_SelectionPollTick must hand selection work to the detached worker")
	for Forbidden in ["UIA.GetFocusedElement", ".GetPattern(", ".GetSelection(", ".GetText("] {
		Assert(InStr(TickBody, Forbidden) = 0,
			"the resident selection timer must not execute cross-process COM on the keyboard thread: " . Forbidden)
	}
	WorkerBody := _DriverFuncBody("UIASW_WorkerHandleRequest")
	Assert(WorkerBody != "" && InStr(WorkerBody, "UIA.GetFocusedElement()") > 0,
		"the real UIA query must exist in the detached worker handler")
	
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

	Root := _USBP_ReadSource("ErgoptiPlus.ahk")
	ReadyPos := InStr(Root, '_DriverBootPhase := "ready"')
	WarmPos := InStr(Root, "SetTimer(UIASW_Start, -1)")
	Assert(ReadyPos > 0 && WarmPos > ReadyPos,
		"the persistent worker must warm immediately after ready so the first wrap action cannot race a cold full-driver child")
	StartBody := _DriverFuncBody("UIASW_Start")
	Assert(InStr(StartBody, "UIASW_WorkerEntryPath()") > 0,
		"source mode must launch the minimal UIA worker entry instead of reparsing the full driver on first use")
	Entry := _USBP_ReadSource("modules/keymap/uia_selection_worker_entry.ahk")
	Assert(InStr(Entry, "vendor\UIA.ahk") > 0
		&& InStr(Entry, "adapters\uia_worker.ahk") > 0
		&& InStr(Entry, "#Include %A_ScriptDir%\uia_selection_worker.ahk") = 0
		&& InStr(Entry, "ErgoptiPlus.ahk") = 0,
		"the source worker entry must contain only its UIA/protocol dependencies, never the resident controller or normal driver boot")
}
Test("layout: UIA selection is polled in background (uia-selection-blocks-keyboard-thread)", _USBP_SelectionIsPolledInBackground)

; The poll tick runs on a SetTimer, which bypasses native Suspend. It must stop
; the detached worker while
; paused (« pause = tout éteint ») and skip the COM work when its only consumer
; (WrapTextIfSelected, gated on wrap_text_if_selected) is disabled.
_USBP_PollTickSuspendAndFeatureGated() {
	Src := _USBP_ReadSource("modules/keymap/layout.ahk")
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(TickBody != "", "_UIA_SelectionPollTick must exist in modules/keymap/layout.ahk")
	Assert(InStr(TickBody, "A_IsSuspended") > 0,
		"_UIA_SelectionPollTick must early-return on A_IsSuspended — SetTimer bypasses native Suspend")
	Assert(InStr(TickBody, 'UIASW_Stop("canceled")') > 0,
		"Suspend must terminate the detached UIA worker, not merely stop posting new requests")
	Assert(InStr(TickBody, "wrap_text_if_selected") > 0,
		"_UIA_SelectionPollTick must skip the COM round-trip when wrap_text_if_selected (its only consumer) is disabled, so non-users never pay the per-tick cost or the large-selection stall risk (uia-poll-bypasses-suspend)")
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "" && InStr(ShutdownBody, 'UIASW_Stop("canceled")') > 0,
		"driver shutdown must retire and terminate the persistent UIA worker so Reload/ExitApp cannot orphan it")
	ResumeBody := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(ResumeBody != "" && InStr(ResumeBody, "SetTimer(UIASW_Start, -1)") > 0,
		"resume must warm the worker that suspend terminated before the next wrap action")
}
Test("layout: UIA selection poll is gated by suspend + the wrap feature flag (uia-poll-bypasses-suspend)", _USBP_PollTickSuspendAndFeatureGated)

; A timer still runs on AHK's sole message thread. It must not post work during
; active typing, and the detached worker must cap the requested TextPattern range.
_USBP_PollTickIsIdleGatedAndBounded() {
	TickBody := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(InStr(TickBody, "A_TimeIdlePhysical < UIA_SELECTION_IDLE_REQUIRED_MS") > 0,
		"_UIA_SelectionPollTick must skip new UIA COM work while physical input is active, so its timer cannot contend with keyboard dispatch")
	WorkerBody := _DriverFuncBody("UIASW_WorkerHandleRequest")
	Assert(WorkerBody != "" && InStr(WorkerBody, "GetText(MaxTextChars)") > 0,
		"the detached worker must cap TextPattern.GetText instead of reading an unbounded document range")
	Assert(InStr(WorkerBody, "GetText(-1)") = 0,
		"the UIA worker must never request an unbounded selection")
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
