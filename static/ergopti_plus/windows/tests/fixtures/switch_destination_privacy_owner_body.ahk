; tests/fixtures/switch_destination_privacy_owner_body.ahk

; ==============================================================================
; MODULE: Captured Switch Destination Privacy Child
; DESCRIPTION:
; Probe identities enter the actual MF acquisition/normalization/commit owner.
; The context getter delegates the real snapshot read before one native timer
; acquires a third focus. This is a scheduling port, not physical OS focus proof.
; No central append or publication is faked and no focus cache is assigned.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSD_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_KSD_Diagnostic(Level, Source, Message, Values*) {
	global _KSD
	if Level == "error" || (Level == "warn" && StrLower(Source) != "hotpath")
		_KSD.Errors += 1
	Text := Message
	try Text := Format(Message, Values*)
	FileAppend(Level . " " . Source . " " . Text . "`n", _KSD.Log, "UTF-8")
}
LoggerError(Source, Message, Values*) {
	_KSD_Diagnostic("error", Source, Message, Values*)
}
LoggerWarn(Source, Message, Values*) {
	_KSD_Diagnostic("warn", Source, Message, Values*)
}
LoggerInfo(Source, Message, Values*) {
	_KSD_Diagnostic("info", Source, Message, Values*)
}

; The entire real flush runs unchanged. Its empty-buffer fast path is observed,
; not replaced; a hidden try in the real hook cannot swallow a fixture failure.
KL_FlushBuffer(PublishGuard := unset, &DeferredByActiveFlush := false) {
	global _KSD
	_KSD.FlushCalls += 1
	try {
		_KSD_Require(Keystats.initialized && Keystats.buffer_events.Length == 0
			&& Keystats._retry_snapshots.Length == 0 && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
			"Every observed real flush must use its genuine empty-buffer path.")
		return _KSD_NativeFlush(PublishGuard?, &DeferredByActiveFlush)
	} catch Any as Failure {
		if !IsObject(_KSD.Failure)
			_KSD.Failure := Failure
		throw Failure
	}
}

; Keep the real producer bodies and exceptions. Their caller's bare try must
; never turn a missing dependency or publication error into privacy success.
_KSD_DelegateLog(Callback, Values*) {
	global _KSD
	_KSD.LogCalls += 1
	try return Callback.Call(Values*)
	catch Any as Failure {
		if !IsObject(_KSD.Failure)
			_KSD.Failure := Failure
		throw Failure
	}
}
KL_LogAppSwitch(Values*) {
	return _KSD_DelegateLog(_KSD_NativeLogAppSwitch, Values*)
}
KL_LogWindowSwitch(Values*) {
	return _KSD_DelegateLog(_KSD_NativeLogWindowSwitch, Values*)
}

_KSD_Probe(Identity, TimeoutMs) {
	global _KSD
	_KSD_Require(!A_IsCritical && TimeoutMs == WI_FOCUS_TITLE_TIMEOUT_MS,
		"The real acquisition must use its canonical bound outside Critical.")
	_KSD.Probes += 1
	return {ok: true, hwnd: Identity.Hwnd, process_name: Identity.App,
		title: Identity.Title, class: "Fixture", failure_reason: "", timed_out: false}
}

_KSD_Acquire(Identity) {
	_KSD_Require(MF_RefreshFocus(true, _KSD_Probe.Bind(Identity)),
		"The actual MF owner must acquire, normalize and publish this identity.")
	Published := MF_GetFocusSnapshot()
	_KSD_Require(Published.valid && Published.hwnd == Identity.Hwnd
		&& Published.process_name == Identity.App && Published.title == Identity.Title,
		"Only the actual published candidate may supply a focus identity.")
	return Published
}

_KSD_Interrupt() {
	global _KSD
	try {
		_KSD_Require(!A_IsCritical && !A_IsSuspended && _KSD.BeforeTimer,
			"A native timer must interrupt the retained snapshot before projection.")
		_KSD.TimerCalls += 1
		_KSD.Current := _KSD_Acquire(_KSD.C)
		_KSD_Require(MetricsFocusCache.generation > _KSD.CapturedGeneration
			&& !MF_ShouldFilter() && !MF_ShouldFilterFor(_KSD.C.App, _KSD.C.Title)
			&& Keystats._pending_entries.Length == _KSD.HistoryRows,
			"The newer public C must publish before any old switch row is admitted.")
	} catch Any as Failure {
		_KSD.Failure := Failure
	} finally _KSD.Done := true
}

_KSD_CapturedSnapshot() {
	global _KSD
	Snapshot := MF_GetFocusSnapshot()
	_KSD_Require(Snapshot == _KSD.Destination && Snapshot.valid && !A_IsCritical,
		"The real context read must retain exactly the acquired B reference.")
	_KSD.CapturedGeneration := MetricsFocusCache.generation
	if !_KSD.Third
		return Snapshot
	_KSD.BeforeTimer := true
	SetTimer(_KSD.Timer, -1)
	Started := A_TickCount
	while !_KSD.Done && TickElapsed64(Started) < 2000
		Sleep(10)
	if IsObject(_KSD.Failure)
		throw _KSD.Failure
	_KSD_Require(_KSD.Done && _KSD.TimerCalls == 1 && MF_GetFocusSnapshot() == _KSD.Current
		&& Snapshot == _KSD.Destination && MetricsFocusCache.generation > _KSD.CapturedGeneration,
		"The retained B and newly acquired C must coexist before the old getter returns.")
	return Snapshot
}

_KSD_Observe(Stage) {
	global _KSD
	PrivateApps := 0, PrivateTitles := 0
	for Index, Row in Keystats._pending_entries {
		if Index <= _KSD.HistoryRows
			continue
		if Row["type"] == "app_switch" && Row["next_app"] == _KSD.B.App && _KSD.AppPrivate
			PrivateApps += 1
		if Row["type"] == "window_switch" && Row["next_title"] == _KSD.B.Title && (_KSD.AppPrivate || _KSD.TitlePrivate)
			PrivateTitles += 1
	}
	FileAppend("RECEIPT switch-destination-owner stage=" . Stage . " mode=" . _KSD.Mode
		. " rows=" . Keystats._pending_entries.Length . " history=" . _KSD.HistoryRows
		. " next_app_private=" . PrivateApps . " next_title_private=" . PrivateTitles
		. " timer_calls=" . _KSD.TimerCalls . " probes=" . _KSD.Probes . " flushes=" . _KSD.FlushCalls
		. " captured_generation=" . _KSD.CapturedGeneration . " generation=" . MetricsFocusCache.generation
		. " log_calls=" . _KSD.LogCalls . " privacy_hits=" . Keystats.health_privacy_hits . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
	return [PrivateApps, PrivateTitles]
}

_KSD_Exercise() {
	global _KSD
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	_KSD.A := {App: "fixture-public-a.exe", Title: "Fixture public A", Hwnd: 102}
	_KSD.B := {App: _KSD.AppPrivate ? "fixture-excluded-b.exe"
		: _KSD.TitlePrivate ? _KSD.A.App : "fixture-public-b.exe",
		Title: _KSD.TitlePrivate ? "Fixture B (Private Browsing)" : "Fixture public B", Hwnd: 103}
	_KSD.C := {App: "fixture-public-c.exe", Title: "Fixture public C", Hwnd: 104}
	H := {App: "fixture-public-history.exe", Title: "Fixture public history", Hwnd: 101}
	_KSD_Acquire(H)
	_KSD_Require(KL_Hook_RefreshContext(true) && Keystats._pending_entries.Length == 0,
		"The first genuine projection must prime its own previous context without a fabricated switch.")
	_KSD_Acquire(_KSD.A)
	_KSD_Require(KL_Hook_RefreshContext(true) && Keystats._pending_entries.Length == 2,
		"The real public transition must first admit an app and a title row.")
	_KSD.HistoryRows := Keystats._pending_entries.Length
	_KSD.HistoryFirst := Keystats._pending_entries[1]
	_KSD.HistorySecond := Keystats._pending_entries[2]
	_KSD_Require(!MF_ShouldFilterFor(_KSD.A.App, _KSD.A.Title),
		"The already-admitted historical A must have been public.")
	if _KSD.AppPrivate
		MetricsFilters.disabled_apps[_KSD.B.App] := true
	if _KSD.Mode == "outgoing-private"
		MetricsFilters.disabled_apps[_KSD.A.App] := true
	_KSD.Destination := _KSD_Acquire(_KSD.B)
	PrivateDestination := MF_ShouldFilterFor(_KSD.B.App, _KSD.B.Title)
	_KSD_Require(PrivateDestination == (_KSD.AppPrivate || _KSD.TitlePrivate),
		"The genuine explicit predicate must authenticate the configured destination privacy.")
	_KSD_Require(MF_ShouldFilterFor(_KSD.A.App, _KSD.A.Title) == (_KSD.Mode == "outgoing-private"),
		"The independent outgoing predicate must authenticate the chosen public or excluded A.")
	_KSD_Require(Keystats.buffer_events.Length == 0 && Keystats._retry_snapshots.Length == 0
		&& !Keystats._flush_in_progress && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
		"The real pre-switch flush must have no detached or live typing state to explain the row.")
	Result := KL_Hook_RefreshContext(true, _KSD_CapturedSnapshot)
	if IsObject(_KSD.Failure)
		throw _KSD.Failure
	_KSD_Require((Result == true || Result == false) && _KSD.Errors == 0 && _KSD.FlushCalls > 0,
		"The genuine projection and observed real flush must not hide prerequisite errors.")
	_KSD_Require(_KSD.TimerCalls == (_KSD.Third ? 1 : 0)
		&& MF_GetFocusSnapshot() == (_KSD.Third ? _KSD.Current : _KSD.Destination),
		"Live-focus and retained-destination preconditions must precede all business assertions.")
	Observed := _KSD_Observe("old-return")
	_KSD_Require(Observed[1] == 0, "A captured excluded next_app must never enter the canonical switch queue.")
	_KSD_Require(Observed[2] == 0, "A captured private next_title must never enter the canonical switch queue.")
	if _KSD.Mode == "outgoing-private" {
		for Index, Row in Keystats._pending_entries {
			if Index > _KSD.HistoryRows
				_KSD_Require(Row["type"] != "app_switch" && Row["type"] != "window_switch",
					"The existing outgoing-app exclusion must still refuse both switch payloads.")
		}
	}
	_KSD_Require(Keystats._pending_entries[1] == _KSD.HistoryFirst
		&& Keystats._pending_entries[2] == _KSD.HistorySecond,
		"Previously admitted public history must stay intact; total queue emptiness is not required.")
	if _KSD.Mode == "public" {
		Found := false
		for Index, Row in Keystats._pending_entries {
			if Index > _KSD.HistoryRows && Row["type"] == "window_switch" && Row["next_title"] == _KSD.B.Title
				Found := true
		}
		_KSD_Require(Found, "A genuine public destination title must remain observable.")
	}
	_KSD_Acquire(_KSD.C)
	_KSD_Require(KL_Hook_RefreshContext(true), "A genuine fresh public projection must settle.")
	D := {App: "fixture-public-d.exe", Title: "Fixture public D", Hwnd: 105}
	_KSD_Acquire(D)
	BeforeRows := Keystats._pending_entries.Length
	_KSD_Require(KL_Hook_RefreshContext(true), "A subsequent public transition must remain enabled.")
	if IsObject(_KSD.Failure)
		throw _KSD.Failure
	AppFound := false, TitleFound := false
	for Index, Row in Keystats._pending_entries {
		if Index <= BeforeRows
			continue
		if Row["type"] == "app_switch" && Row["next_app"] == D.App
			AppFound := true
		if Row["type"] == "window_switch" && Row["next_title"] == D.Title
			TitleFound := true
	}
	_KSD_Require(AppFound && TitleFound && _KSD.Errors == 0 && !Keystats._flush_in_progress,
		"Public app/title destinations must remain observable without a hidden publication failure.")
	_KSD_Observe("complete")
}

_KSD_Main() {
	if A_Args.Length != 2
		ExitApp(2)
	Persistent(true)
	global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Timer: _KSD_Interrupt,
		Third: InStr(A_Args[1], "-third") > 0, AppPrivate: InStr(A_Args[1], "app-") == 1,
		TitlePrivate: InStr(A_Args[1], "title-") == 1, HistoryRows: 0, FlushCalls: 0,
		Probes: 0, LogCalls: 0, Errors: 0, TimerCalls: 0, BeforeTimer: false, Done: false,
		CapturedGeneration: -1, Failure: 0}
	Primary := 0
	try _KSD_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		SetTimer(_KSD.Timer, 0)
		_KSD.Timer := 0
		Keystats.initialized := false
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8")
		if FileExist(_KSD.Log) {
			for Line in StrSplit(FileRead(_KSD.Log, "UTF-8"), "`n", "`r")
				if Line != ""
					FileAppend("DIAG " . Line . "`n", "*", "UTF-8")
		}
		ExitApp(1)
	}
	FileAppend("PASS switch-destination-owner " . _KSD.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
}

_KSD_Main()
