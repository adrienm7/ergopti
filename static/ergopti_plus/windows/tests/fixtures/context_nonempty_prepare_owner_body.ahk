; tests/fixtures/context_nonempty_prepare_owner_body.ahk

; The real context preparation detaches a nonempty A snapshot. During its real
; privacy classification an independent native timer admits five public pointer
; distance units under canonical B, then optionally invokes the actual Stop.
; Pointer coordinates are isolated ports; this is not physical hardware input.
#Requires AutoHotkey v2.0

KLWV_NotifyIngest(*) => true
_KCNP_Position() {
	global _KCNP
	_KCNP.Samples += 1
	return {x: (_KCNP.Samples - 1) * 3, y: (_KCNP.Samples - 1) * 4}
}
_KCNP_Timer() {
	global _KCNP
	try {
		_KSD_Require(Keystats._flush_in_progress && Keystats.mouse_distance == 0,
			"The original A snapshot must already be detached while its real flush is active")
		_KSD_Require(MetricsFocusCache.state.process_name == _KCNP.B.App,
			"The actual canonical privacy owner must already identify the public B input")
		_KCNP.SessionAtInput := Keystats.session_app
		KL_Mouse_ParkTick(, _KCNP_Position)
		_KSD_Require(Keystats.mouse_distance == 5 && _KCNP.Samples == 3,
			"The genuine public pointer producer must add exactly five new units into the fresh live buffer")
		if _KCNP.Mode == "stop-during-prepare" {
			_KCNP.FirstStop := KL_Hook_Stop()
			_KSD_Require(!_KCNP.FirstStop && KLHook.capture_stopping && IsObject(KLHook.context_stop),
				"The nested real Stop must retain its close while the original nonempty flush is still active")
		}
	} catch Any as Failure {
		_KCNP.Failure := Failure
	} finally _KCNP.TimerDone := true
}
MF_ShouldFilter() {
	global _KCNP
	Result := _KCNP_ActualFilter()
	if IsSet(_KCNP) && _KCNP.Armed && Keystats._flush_in_progress {
		_KCNP.Armed := false
		_KCNP.Cutpoints += 1
		_KSD_Require(!Result, "The real privacy predicate must accept both public contexts before scheduling input")
		SetTimer(_KCNP_Timer, -1)
		Started := A_TickCount
		while !_KCNP.TimerDone && TickElapsed64(Started) < 2500
			Sleep(5)
		if IsObject(_KCNP.Failure)
			throw _KCNP.Failure
		_KSD_Require(_KCNP.TimerDone, "The independent native timer must finish before the original flush predicate returns")
	}
	return Result
}
_KCNP_Main() {
	global _KSD, _KCNP
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	A := {App: "fixture-prepare-a.exe", Title: "Public prepare A", Hwnd: 1801}
	_KCNP.B := {App: "fixture-prepare-b.exe", Title: "Public prepare B", Hwnd: 1802}
	KLAppCat.file_path := _KSD.Log . ".categories"
	for Identity in [A, _KCNP.B]
		KLAppCat.categories[Identity.App] := Map("type", "fixture-known", "score", 0)
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The actual initial public A must establish its native context")
	KL_Mouse_ParkTick(, _KCNP_Position)
	KL_Mouse_ParkTick(, _KCNP_Position)
	_KSD_Require(Keystats.mouse_distance == 5 && Keystats.session_app == A.App,
		"Exactly five original units must belong to A before the transition")
	Sleep(30)
	_KSD_Acquire(_KCNP.B)
	_KCNP.Armed := true
	_KCNP.RefreshReturned := KL_Hook_RefreshContext(true)
	if IsObject(_KCNP.Failure)
		throw _KCNP.Failure
	_KSD_Require(_KCNP.Cutpoints == 1 && _KCNP.TimerDone && _KCNP.Samples == 3,
		"A real nonempty flush and its one native input/Stop cutpoint must execute")
	_KCNP.FinalStop := KL_Hook_Stop()
	_KSD_Require(_KCNP.FinalStop, "The actual final Stop or retained Stop retry must settle before attribution is sampled")
	AUnits := 0, BUnits := 0, Rows := 0
	for Entry in Keystats._pending_entries {
		FileAppend("ROW " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		if Entry["type"] != "typing"
			continue
		Rows += 1
		if Entry["app"] == A.App
			AUnits += Entry["mouse_distance_px"]
		else if Entry["app"] == _KCNP.B.App
			BUnits += Entry["mouse_distance_px"]
	}
	FileAppend("OBSERVATION context-nonempty-prepare mode=" . _KCNP.Mode . " first_stop=" . _KCNP.FirstStop
		. " final_stop=" . _KCNP.FinalStop . " refresh_returned=" . _KCNP.RefreshReturned
		. " live_session_at_b_input=" . _KCNP.SessionAtInput . " a_units=" . AUnits . " b_units=" . BUnits
		. " typing_rows=" . Rows . " samples=" . _KCNP.Samples . " errors=" . _KSD.Errors . "`n", "*")
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "No dependency failure may impersonate a context transition refusal")
	_KSD_Require(AUnits == 5 && BUnits == 5 && Rows == 2,
		"A new public B input admitted during nonempty preparation must never be flushed under the older A context after Stop or retry")
}
if A_Args.Length != 2 || !(A_Args[1] == "ordinary-control" || A_Args[1] == "stop-during-prepare")
	throw Error("The private nonempty context probe requires its exact mode and owned source directory")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
global _KCNP := {Mode: A_Args[1], B: 0, Armed: false, Samples: 0, Cutpoints: 0, TimerDone: false,
	FirstStop: false, FinalStop: false, RefreshReturned: false, SessionAtInput: "", Failure: 0}
try {
	_KCNP_Main()
	FileAppend("PASS context-nonempty-prepare " . _KCNP.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as KCNPEntryFailure {
	FileAppend("FAIL context-nonempty-prepare " . KCNPEntryFailure.Message . " [" . KCNPEntryFailure.File . ":" . KCNPEntryFailure.Line . "]`n", "*", "UTF-8")
	ExitApp(1)
} finally {
	SetTimer(_KCNP_Timer, 0)
	Keystats.initialized := false
}
