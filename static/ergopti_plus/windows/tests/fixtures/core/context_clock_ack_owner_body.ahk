; tests/fixtures/core/context_clock_ack_owner_body.ahk
; Actual central acceptance then native timer Stop before the interrupted refresh returns.
#Requires AutoHotkey v2.0

_KTAC_State() => [KLHook.prev_app, KLHook.app_entered_at, KLHook.prev_title,
	KLHook.title_entered_at, Keystats.session_app, Keystats.session_title, KLHook.context_at]

_KTAC_Boundary() {
	global _KTAC
	try {
		_KSD_Require(!A_IsCritical && !_KTAC.Done, "The native cutpoint must interrupt the retained accepted-producer frame.")
		_KTAC.TimerCalls += 1
		if _KTAC.ThirdRequested {
			_KSD_Acquire({App: "fixture-tail-c.exe", Title: "Fixture destination title C", Hwnd: 1103})
			_KTAC.ThirdReturned := KL_Hook_RefreshContext(true)
		}
		if _KTAC.StopRequested {
			_KTAC.StopReturn := KL_Hook_Stop()
			_KSD_Require(KLHook.capture_stopping && KLHook.HasOwnProp("registered") && !KLHook.registered,
				"The actual public Hook_Stop must retire native capture before sampling its state.")
		}
		_KTAC.AfterBoundary := _KTAC_State()
		_KTAC.RowsAtBoundary := Keystats._pending_entries.Length
		_KTAC.End := A_TickCount
	} catch Any as Failure {
		_KTAC.Failure := Failure
	} finally _KTAC.Done := true
}

_KTAC_ObserveAccepted(Stage, BeforeRows) {
	global _KTAC
	if _KTAC.Fired || Stage != _KTAC.Stage
		return
	_KSD_Require(Keystats._pending_entries.Length == BeforeRows + 1,
		"Only a genuine newly accepted central row may activate this cutpoint.")
	Row := Keystats._pending_entries[-1]
	_KSD_Require(Row["type"] == (Stage == "app" ? "app_switch" : "window_switch")
		&& Row["duration_ms"] >= 30 && Row.Has("_event_id") && Row["_event_id"] > 0,
		"The real producer must already have published its timed source interval before any stop.")
	_KTAC.Fired := true
	SetTimer(_KTAC_Boundary, -1)
	Started := A_TickCount
	while !_KTAC.Done && TickElapsed(Started) < 2000
		Sleep(5)
	if IsObject(_KTAC.Failure)
		throw _KTAC.Failure
	_KSD_Require(_KTAC.Done && _KTAC.TimerCalls == 1,
		"One real timer must return from public Stop before the original public logger returns.")
}

KL_LogAppSwitch(Values*) {
	BeforeRows := Keystats._pending_entries.Length
	Result := _KSD_DelegateLog(_KSD_NativeLogAppSwitch, Values*)
	_KTAC_ObserveAccepted("app", BeforeRows)
	return Result
}

KL_LogWindowSwitch(Values*) {
	BeforeRows := Keystats._pending_entries.Length
	Result := _KSD_DelegateLog(_KSD_NativeLogWindowSwitch, Values*)
	_KTAC_ObserveAccepted("title", BeforeRows)
	return Result
}

_KTAC_Main() {
	global _KSD, _KTAC
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	_KSD_Acquire({App: "fixture-tail-a.exe", Title: "Fixture source title A", Hwnd: 1101})
	_KSD_Require(KL_Hook_RefreshContext(true), "The genuine source interval must have a native origin.")
	_KTAC.Origin := KLHook.app_entered_at
	Sleep(40)
	_KSD_Acquire({App: "fixture-tail-b.exe", Title: "Fixture destination title B", Hwnd: 1102})
	Returned := KL_Hook_RefreshContext(true)
	_KSD_Require(_KTAC.Fired && _KTAC.Done && _KTAC.TimerCalls == 1
		&& _KSD.Errors == 0 && !IsObject(_KSD.Failure),
		"Accepted-row/timer prerequisites cannot be replaced by a swallowed dependency error.")
	if _KTAC.ThirdRequested {
		_KSD_Require(KL_Hook_RefreshContext(true), "The current C context must settle after the interrupted owner returns.")
		_KSD_Require(KL_Hook_Stop(), "The real close must settle the current C interval.")
		AppAB := 0, AppBC := 0, TitleAB := 0, TitleBC := 0
		for Row in Keystats._pending_entries {
			if Row["type"] == "app_switch" {
				if Row["prev_app"] == "fixture-tail-a.exe" && Row["next_app"] == "fixture-tail-b.exe"
					AppAB += 1
				if Row["prev_app"] == "fixture-tail-b.exe" && Row["next_app"] == "fixture-tail-c.exe"
					AppBC += 1
			} else if Row["type"] == "window_switch" {
				if Row["prev_title"] == "Fixture source title A" && Row["next_title"] == "Fixture destination title B"
					TitleAB += 1
				if Row["prev_title"] == "Fixture destination title B" && Row["next_title"] == "Fixture destination title C"
					TitleBC += 1
			}
		}
		FileAppend("OBSERVATION partial-ack third_returned=" . _KTAC.ThirdReturned . " app_ab=" . AppAB
			. " app_bc=" . AppBC . " title_ab=" . TitleAB . " title_bc=" . TitleBC . "`n", "*")
		_KSD_Require(AppAB == 1 && AppBC == 1 && TitleAB == 1 && TitleBC == 1,
			"A third observation during actual app/title ACK must retain every exact clock receipt once.")
	}
	After := _KTAC_State(), Stable := true
	for Index, Value in After
		if !(Value == _KTAC.AfterBoundary[Index])
			Stable := false
	for Row in Keystats._pending_entries
		FileAppend("ROW " . KL_JsonEncode(Row) . "`n", "*", "UTF-8")
	FileAppend("STATE " . Stable . "|" . _KTAC.RowsAtBoundary . "|" . Keystats._pending_entries.Length
		. "|" . TickElapsed(_KTAC.Origin, _KTAC.End) . "|" . _KTAC.Stage . "|" . _KTAC.StopRequested . "`n", "*", "UTF-8")
	FileAppend("RECEIPT context-clock-ack mode=" . A_Args[1] . " stable=" . Stable . " timer_calls=" . _KTAC.TimerCalls
		. " rows_at_boundary=" . _KTAC.RowsAtBoundary . " rows_after_return=" . Keystats._pending_entries.Length
		. " returned=" . Returned . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
}

if A_Args.Length != 2 || !(A_Args[1] == "app-control" || A_Args[1] == "title-control" || A_Args[1] == "app-stop" || A_Args[1] == "title-stop" || A_Args[1] == "app-third" || A_Args[1] == "title-third")
	throw Error("The private context ACK child requires an exact mode and owned directory.")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
global _KTAC := {Stage: InStr(A_Args[1], "app-") == 1 ? "app" : "title", StopRequested: InStr(A_Args[1], "-stop") > 0,
	ThirdRequested: InStr(A_Args[1], "-third") > 0, ThirdReturned: false,
	Fired: false, Done: false, Failure: 0, TimerCalls: 0, Origin: 0, End: 0, AfterBoundary: [], RowsAtBoundary: 0, StopReturn: ""}
try {
	_KTAC_Main()
	FileAppend("PASS context-clock-ack " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KTAC_EntryFailure {
	FileAppend("FAIL context-clock-ack " . _KTAC_EntryFailure.Message . " [" . _KTAC_EntryFailure.File . ":" . _KTAC_EntryFailure.Line . "]`n", "*", "UTF-8")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8")
	ExitApp(1)
} finally {
	SetTimer(_KTAC_Boundary, 0)
	Keystats.initialized := false
}
