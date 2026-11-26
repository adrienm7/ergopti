; tests/fixtures/final_context_duration_owner_body.ahk
; Real context and hook stop producers, genuine empty flush and pending append.
#Requires AutoHotkey v2.0

_KFCD_Main() {
	global _KSD
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	A := {App: "fixture-final-context-a.exe", Title: "Fixture final source A", Hwnd: 801}
	B := {App: "fixture-final-context-b.exe", Title: "Fixture final source B", Hwnd: 802}
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The real initial context must publish.")
	Origin := KLHook.app_entered_at
	_KSD_Require(Origin > 0 && KLHook.prev_app == A.App, "The real native context origin must exist.")
	Sleep(50)
	if A_Args[1] == "switch-control" {
		_KSD_Acquire(B)
		_KSD_Require(KL_Hook_RefreshContext(true), "The real control must close A through a normal app switch.")
	}
	_KSD_Require((!KLHook.HasOwnProp("registered") || !KLHook.registered) && !KLPasswordCache.focus_tracking_active
		&& !KLPasswordCache.focus_hook && !KLPasswordCache.focus_callback,
		"No physical input/password hook is installed by this isolated fixture.")
	KL_Hook_Stop()
	_KSD_Require(KLHook.capture_stopping && KLHook.HasOwnProp("registered")
		&& !KLHook.registered && _KSD.FlushCalls > 0,
		"The genuine public stop must invalidate capture and reach the real empty flush.")
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "A hidden try cannot turn a dependency failure into success.")
	Rows := 0
	for Row in Keystats._pending_entries {
		if Row["type"] == "app_switch" || Row["type"] == "window_switch" {
			FileAppend("ROW " . KL_JsonEncode(Row) . "`n", "*", "UTF-8")
			Rows += 1
		}
	}
	FileAppend("RECEIPT final-context-duration mode=" . A_Args[1] . " rows=" . Rows
		. " elapsed=" . TickElapsed(Origin) . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
}

if A_Args.Length != 2 || !(A_Args[1] == "terminal" || A_Args[1] == "switch-control")
	throw Error("The private final context case requires an exact mode and owned directory.")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
try {
	_KFCD_Main()
	FileAppend("PASS final-context-duration " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KFCD_EntryFailure {
	FileAppend("FAIL final-context-duration " . _KFCD_EntryFailure.Message . " [" . _KFCD_EntryFailure.File . ":" . _KFCD_EntryFailure.Line . "]`n", "*", "UTF-8")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8")
	ExitApp(1)
} finally Keystats.initialized := false
