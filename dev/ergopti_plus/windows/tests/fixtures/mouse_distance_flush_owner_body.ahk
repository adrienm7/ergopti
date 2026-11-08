; tests/fixtures/mouse_distance_flush_owner_body.ahk
; Actual public pointer samples, distance accumulation, full flush and canonical append.
#Requires AutoHotkey v2.0

_KMD_Position(State) {
	State.Index += 1
	return State.Index == 1 ? {x: 0, y: 0} : {x: 3, y: 4}
}

KLWV_NotifyIngest(*) { ; passive dashboard wake-up observer, never a flush/append substitute
	return true
}

_KMD_Main() {
	global _KSD
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	App := "fixture-distance-owner.exe"
	_KSD_Acquire({App: App, Title: "Fixture public pointer distance", Hwnd: 1001})
	_KSD_Require(KL_Hook_RefreshContext(true), "The actual public context must own the movement.")
	; Same known-category setup as the existing full detached-snapshot fixture:
	; retain real category lookup while avoiding unrelated deferred file writes.
	KLAppCat.file_path := _KSD.Log . ".categories"
	KLAppCat.categories[App] := Map("type", "fixture-known", "score", 0)
	Position := {Index: 0}
	KL_Mouse_ParkTick(, _KMD_Position.Bind(Position))
	KL_Mouse_ParkTick(, _KMD_Position.Bind(Position))
	_KSD_Require(Position.Index == 2 && Keystats.mouse_distance == 5
		&& Keystats.buffer_events.Length == 0 && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
		"Real accepted pointer samples must generate exactly five distance units without a fabricated click or key.")
	if A_Args[1] == "with-click-control"
		KL_BumpMouseClick()
	if A_Args[1] == "periodic-movement-only"
		KL_Hook_Tick()
	else
		_KSD_Require(KL_FlushBuffer(), "The public direct flush must report its actual result.")
	if KLHook.HasOwnProp("live_push_timer") && IsObject(KLHook.live_push_timer)
		SetTimer(KLHook.live_push_timer, 0)
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure) && !Keystats._flush_in_progress,
		"No category, privacy or publication error may qualify a missing distance row.")
	for Row in Keystats._pending_entries
		FileAppend("ROW " . KL_JsonEncode(Row) . "`n", "*", "UTF-8")
	FileAppend("RECEIPT mouse-distance-flush mode=" . A_Args[1] . " samples=" . Position.Index
		. " pending_rows=" . Keystats._pending_entries.Length . " remaining_distance=" . Keystats.mouse_distance
		. " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
}

if A_Args.Length != 2 || !(A_Args[1] == "direct-movement-only" || A_Args[1] == "periodic-movement-only" || A_Args[1] == "with-click-control")
	throw Error("The private distance-flush child requires an exact mode and owned directory.")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
try {
	_KMD_Main()
	FileAppend("PASS mouse-distance-flush " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KMD_EntryFailure {
	FileAppend("FAIL mouse-distance-flush " . _KMD_EntryFailure.Message . " [" . _KMD_EntryFailure.File . ":" . _KMD_EntryFailure.Line . "]`n", "*", "UTF-8")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8")
	ExitApp(1)
} finally {
	if KLHook.HasOwnProp("live_push_timer") && IsObject(KLHook.live_push_timer)
		SetTimer(KLHook.live_push_timer, 0)
	Keystats.initialized := false
}
