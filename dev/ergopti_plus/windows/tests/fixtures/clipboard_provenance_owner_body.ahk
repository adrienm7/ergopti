; tests/fixtures/clipboard_provenance_owner_body.ahk

; ==============================================================================
; MODULE: Clipboard Provenance Native Owner Child
; DESCRIPTION:
; Actual clipboard handlers, MF refresh/classification, hook context projection
; and central append run unchanged. Only native focus/classification ports are
; controlled. Handler delivery uses nontext type 2; no OS clipboard is touched.
; ==============================================================================

#Requires AutoHotkey v2.0

_KPCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Diagnostics/profiling are passive; unexpected errors cannot qualify a refusal.
LoggerInfo(*) {
}
LoggerWarn(*) => _KPCO_UnexpectedDiagnostic()
LoggerError(*) => _KPCO_UnexpectedDiagnostic()
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
_KPCO_UnexpectedDiagnostic() {
	global _KPCO
	_KPCO.Diagnostics += 1
}

; MF_RefreshFocus receives this OS acquisition port through its real API.
; The returned identifiers are private fixture data, not native focus claims.
_KPCO_Acquire(Timeout) {
	global _KPCO
	_KPCO.Acquisitions += 1
	Frame := _KPCO.NativeFrame
	return {ok: true, hwnd: Frame.Hwnd, process_name: Frame.App,
		title: Frame.Title, class: "Edit"}
}

_KPCO_Focus(Frame) {
	global _KPCO
	_KPCO.NativeFrame := Frame
	_KPCO_Require(MF_RefreshFocus(true, _KPCO_Acquire),
		"The actual MF owner must admit this complete native-port snapshot.")
	_KPCO_Require(!Keystats._flush_in_progress && Keystats._retry_snapshots.Length == 0
		&& Keystats.buffer_events.Length == 0 && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
		"The actual context refresh must use the genuine empty-buffer flush branch.")
	_KPCO_Require(KL_Hook_RefreshContext(true),
		"The actual hook owner must project the admitted MF snapshot.")
	Snapshot := MF_GetFocusSnapshot()
	_KPCO_Require(Snapshot.valid && Snapshot.hwnd == Frame.Hwnd
		&& Snapshot.process_name == Frame.App && Keystats.session_app == Frame.App,
		"Both real context consumers must expose this exact admitted source.")
}

; This OS port captures its result before the controlled eligible native timer.
; It does not claim that GetForegroundWindow itself blocks/pumps for this long.
KL_FocusedHostHwnd() {
	global _KPCO
	Captured := _KPCO.NativeFrame.Hwnd
	_KPCO.FocusReads += 1
	if !_KPCO.Armed
		return Captured
	_KPCO.Armed := false
	try {
		_KPCO_Require(!A_IsCritical, "The native focus cutpoint must be interruptible.")
		_KPCO.SnapshotA := MF_GetFocusSnapshot()
		_KPCO_Require(_KPCO.SnapshotA.process_name == _KPCO.PublicA.App,
			"The clipboard filter must first capture the genuine public A snapshot.")
		SetTimer(_KPCO.TransitionTimer, -1)
		Started := A_TickCount
		while !_KPCO.TransitionDone && TickElapsed(Started) < 2000
			Sleep(10)
		_KPCO_Require(_KPCO.TransitionDone && _KPCO.TransitionCalls == 1,
			"The real B focus timer must settle before the original probe returns.")
	} catch Any as Failure {
		if !IsObject(_KPCO.Failure)
			_KPCO.Failure := Failure
	}
	return Captured
}

; A conclusive ordinary Win32 Edit result needs no fabricated safe UIA cache
; or live focus-hook permission. The real detector/cache writer consumes it.
KL_DetectPasswordCheap(Hwnd, &Conclusive) {
	global _KPCO
	_KPCO.CheapReads += 1
	_KPCO_Require(Hwnd == _KPCO.PublicA.Hwnd || Hwnd == _KPCO.PrivateB.Hwnd
		|| Hwnd == _KPCO.PublicC.Hwnd, "Every password probe must use a known native-port HWND.")
	Conclusive := true
	return false
}
KL_SchedulePasswordDetect(*) {
	throw Error("The conclusive native Edit port must not request a UIA worker.")
}

_KPCO_Transition() {
	global _KPCO
	try {
		_KPCO_Require(!A_IsCritical && !A_IsSuspended,
			"The real focus timer must execute while the original callback is eligible.")
		_KPCO.TransitionCalls += 1
		_KPCO_Focus(_KPCO.PrivateB)
		_KPCO.SnapshotB := MF_GetFocusSnapshot()
		_KPCO.HitsAfterB := Keystats.health_privacy_hits
		_KPCO.RowsAfterB := Keystats._pending_entries.Length
	} catch Any as Failure {
		if !IsObject(_KPCO.Failure)
			_KPCO.Failure := Failure
	} finally {
		_KPCO.TransitionDone := true
	}
}

_KPCO_Pause() {
	global _KPCO
	try {
		Suspend(true)
		_KPCO.PauseObserved := A_IsSuspended
		_KPCO_Require(_KPCO.PauseObserved, "Native Suspend must actually be active.")
		KL_Clip_OnPaste()
		_KPCO_Require(Keystats._pending_entries.Length == 1 && KLClip.paste_ticks.Length == 0,
			"A handler delivered while paused must not admit a row or burst tick.")
		SetTimer(_KPCO.ResumeTimer, -1)
	} catch Any as Failure {
		if !IsObject(_KPCO.Failure)
			_KPCO.Failure := Failure
		_KPCO.ResumeDone := true
	}
}
_KPCO_Resume() {
	global _KPCO
	Suspend(false)
	_KPCO.ResumeObserved := !A_IsSuspended
	_KPCO.ResumeDone := true
}

_KPCO_Rows(Type) {
	Rows := []
	for Entry in Keystats._pending_entries
		if Entry["type"] == Type
			Rows.Push(Entry)
	return Rows
}

_KPCO_Observe() {
	global _KPCO, _KL_CLIP_FILTER_PROBE
	Pastes := _KPCO_Rows("clipboard_paste")
	Source := Pastes.Length ? Pastes[Pastes.Length]["source_app"] : "<no-paste-row>"
	FileAppend("RECEIPT clipboard-provenance-owner mode=" . _KPCO.Mode
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " root=" . A_Args[2]
		. " snapshot_a=" . (IsObject(_KPCO.SnapshotA) ? _KPCO.SnapshotA.process_name : "<none>")
		. " snapshot_b=" . (IsObject(_KPCO.SnapshotB) ? _KPCO.SnapshotB.process_name : "<none>")
		. " snapshot_c=" . (IsObject(_KPCO.SnapshotC) ? _KPCO.SnapshotC.process_name : "<none>")
		. " rows=" . Keystats._pending_entries.Length . " copies=" . _KPCO_Rows("clipboard_copy").Length
		. " pastes=" . Pastes.Length . " private_copy_refused=" . _KPCO.PrivateCopyRefused
		. " rows_after_b=" . _KPCO.RowsAfterB . " copy_source=" . KLClip.last_copy_app
		. " copy_tick=" . KLClip.last_copy_tick . " copy_len=" . KLClip.last_copy_len
		. " copy_started=" . _KPCO.CopyStarted . " copy_finished=" . _KPCO.CopyFinished
		. " paste_finished=" . _KPCO.PasteFinished
		. " producer_privacy_hits=" . _KPCO.ProducerPrivacyHits
		. " central_probe_refused=" . _KPCO.CentralProbeRefused
		. " paste_source=" . Source . " filter_probe_default=" . (_KL_CLIP_FILTER_PROBE == 0)
		. " acquisitions=" . _KPCO.Acquisitions . " focus_reads=" . _KPCO.FocusReads
		. " cheap_reads=" . _KPCO.CheapReads . " transition_calls=" . _KPCO.TransitionCalls
		. " paused=" . _KPCO.PauseObserved . " resumed=" . _KPCO.ResumeObserved . "`n", "*", "UTF-8-RAW")
	; The actual queue is encoded by genuine production helpers, without a sink
	; mirror or a content-bearing clipboard read. All app/title values are ours.
	FileAppend("QUEUE clipboard-provenance-owner " . KL_JsonEncode(Keystats._pending_entries) . "`n", "*", "UTF-8-RAW")
	for Label, Snapshot in Map("a", _KPCO.SnapshotA, "b", _KPCO.SnapshotB, "c", _KPCO.SnapshotC) {
		if IsObject(Snapshot)
			FileAppend("SNAPSHOT clipboard-provenance-owner " . Label . " "
				. KL_JsonEncode(Map("valid", Snapshot.valid, "hwnd", Snapshot.hwnd,
					"app", Snapshot.process_name, "title", Snapshot.title, "class", Snapshot.class))
				. "`n", "*", "UTF-8-RAW")
	}
}

_KPCO_Exercise() {
	global _KPCO, _KL_CLIP_FILTER_PROBE
	_KPCO_Require(_KL_CLIP_FILTER_PROBE == 0 && !KLPasswordCache.focus_tracking_active,
		"The default privacy path must use real MF without invented focus-hook authority.")
	Keystats.initialized := true
	MetricsFilters.disabled_apps := Map(_KPCO.PrivateB.App, true)
	_KPCO_Focus(_KPCO.Mode == "private-entry" ? _KPCO.PrivateB : _KPCO.PublicA)
	_KPCO.SnapshotA := MF_GetFocusSnapshot()
	_KPCO.Armed := _KPCO.Mode == "late-focus"
	_KPCO.CopyStarted := A_TickCount
	KL_Clip_OnChange(2)
	_KPCO.CopyFinished := A_TickCount
	if IsObject(_KPCO.Failure)
		throw _KPCO.Failure
	if _KPCO.Mode == "late-focus" {
		_KPCO_Require(_KPCO.TransitionCalls == 1 && _KPCO.SnapshotB.valid
			&& _KPCO.SnapshotB.process_name == _KPCO.PrivateB.App
			&& MF_GetFocusSnapshot() == _KPCO.SnapshotB && Keystats.session_app == _KPCO.PrivateB.App,
			"Private B must really publish before the original native probe returns.")
		_KPCO.ProducerPrivacyHits := Keystats.health_privacy_hits - _KPCO.HitsAfterB
		_KPCO.PrivateCopyRefused := true
		for Entry in _KPCO_Rows("clipboard_copy")
			if Entry.Get("app", "") == _KPCO.PrivateB.App
				_KPCO.PrivateCopyRefused := false
		_KPCO_Require(_KPCO.PrivateCopyRefused,
			"The actual producer must not admit a private-source copy row.")
		; A correct producer may now retire before calling the sink. Independently
		; prove its canonical sink refuses this same private source, not a fake sink.
		HitsBeforeProbe := Keystats.health_privacy_hits
		RowsBeforeProbe := Keystats._pending_entries.Length
		_KPCO.CentralProbeRefused := !KL_AppendLog(Map("type", "clipboard_copy",
			"app", _KPCO.PrivateB.App, "content_type", "other", "char_count", 0))
		_KPCO_Require(_KPCO.CentralProbeRefused && Keystats._pending_entries.Length == RowsBeforeProbe
			&& Keystats.health_privacy_hits == HitsBeforeProbe + 1,
			"The actual central append must reject the private-source copy probe.")
	} else if _KPCO.Mode == "private-entry" {
		_KPCO.PrivateCopyRefused := Keystats._pending_entries.Length == 0
		_KPCO_Require(_KPCO.PrivateCopyRefused && KLClip.last_copy_tick == 0,
			"An initially private copy must retire provenance before any later paste.")
	} else {
		_KPCO_Require(_KPCO_Rows("clipboard_copy").Length == 1
			&& KLClip.last_copy_app == _KPCO.PublicA.App && KLClip.last_copy_tick > 0,
			"The positive public handler must reach real append with its provenance.")
	}
	if _KPCO.Mode == "pause-preserve" {
		CopyTick := KLClip.last_copy_tick
		SetTimer(_KPCO.PauseTimer, -1)
		Started := A_TickCount
		while !_KPCO.ResumeDone && TickElapsed(Started) < 2000
			Sleep(10)
		if IsObject(_KPCO.Failure)
			throw _KPCO.Failure
		_KPCO_Require(_KPCO.ResumeDone && _KPCO.PauseObserved && _KPCO.ResumeObserved
			&& KLClip.last_copy_tick == CopyTick && KLClip.last_copy_app == _KPCO.PublicA.App,
			"Native pause/resume without a clipboard change must preserve an admitted public copy.")
	} else {
		_KPCO_Focus(_KPCO.PublicC)
	}
	_KPCO.SnapshotC := MF_GetFocusSnapshot()
	KL_Clip_OnPaste()
	_KPCO.PasteFinished := A_TickCount
	_KPCO_Observe()
	_KPCO_Require(_KPCO.Diagnostics == 0 && !IsObject(_KPCO.Failure),
		"An unexpected diagnostic or native-boundary failure cannot qualify the business oracle.")
	Pastes := _KPCO_Rows("clipboard_paste")
	_KPCO_Require(Pastes.Length == 1, "Exactly one genuine central paste row must be admitted.")
	Paste := Pastes[1]
	if _KPCO.Mode == "late-focus" {
		; The handler began with a genuine public A observation. A safe fix may
		; preserve that exact origin or retire it; it may never invent private B.
		Unknown := Paste["source_app"] == "" && Paste["copy_lag_ms"] == -1 && Paste["char_count"] == 0
			&& KLClip.last_copy_tick == 0 && KLClip.last_copy_len == 0 && KLClip.last_copy_app == ""
		PublicOrigin := Paste["source_app"] == _KPCO.PublicA.App && Paste["char_count"] == 0
			&& Paste["copy_lag_ms"] >= 0 && Paste["copy_lag_ms"] <= TickElapsed(_KPCO.CopyStarted, _KPCO.PasteFinished)
			&& KLClip.last_copy_app == _KPCO.PublicA.App && KLClip.last_copy_len == 0
			&& KLClip.last_copy_tick >= _KPCO.CopyStarted && KLClip.last_copy_tick <= _KPCO.CopyFinished
		_KPCO_Require(Unknown || PublicOrigin,
			"A later public paste must retain only its captured public A origin or exact unknown provenance, never excluded B.")
		_KPCO_Require(_KPCO_Rows("clipboard_copy").Length <= 1,
			"One handler delivery may admit at most one authorized copy row.")
		for Entry in Keystats._pending_entries {
			for Key, Value in Entry
				_KPCO_Require(!(Value is String) || (Value !== _KPCO.PrivateB.App && Value !== _KPCO.PrivateB.Title),
					"No actual central row may expose the excluded B source/context.")
			if Entry["type"] == "clipboard_copy"
				_KPCO_Require(Entry["app"] == _KPCO.PublicA.App && Entry["char_count"] == 0
					&& Entry["content_type"] == "other", "Only the genuinely observed public A copy may be admitted.")
		}
	} else if _KPCO.Mode == "private-entry" {
		_KPCO_Require(Paste["source_app"] == "" && Paste["copy_lag_ms"] == -1 && Paste["char_count"] == 0,
			"A copy refused for private source must not lend provenance to a later public paste.")
	} else {
		_KPCO_Require(Paste["source_app"] == _KPCO.PublicA.App && Paste["copy_lag_ms"] >= 0,
			"An admitted public copy must retain its real provenance, including across pause/resume.")
	}
}

_KPCO_OnError(Failure, *) {
	global _KPCO
	if !IsObject(_KPCO.Failure)
		_KPCO.Failure := Failure
	return true
}

_KPCO_Main() {
	global _KPCO
	if A_Args.Length != 2
		ExitApp(2)
	_KPCO := {Mode: A_Args[1], PublicA: {Hwnd: 701, App: "public-a.exe", Title: "Public A"},
		PrivateB: {Hwnd: 702, App: "private-b.exe", Title: "Private B"},
		PublicC: {Hwnd: 703, App: "public-c.exe", Title: "Public C"},
		NativeFrame: 0, Armed: false, Failure: 0, Diagnostics: 0,
		Acquisitions: 0, FocusReads: 0, CheapReads: 0, TransitionCalls: 0, TransitionDone: false,
		HitsAfterB: 0, RowsAfterB: -1, PrivateCopyRefused: false,
		ProducerPrivacyHits: 0, CentralProbeRefused: false, CopyStarted: 0, CopyFinished: 0, PasteFinished: 0,
		SnapshotA: 0, SnapshotB: 0, SnapshotC: 0, PauseObserved: false,
		ResumeObserved: false, ResumeDone: false,
		TransitionTimer: _KPCO_Transition, PauseTimer: _KPCO_Pause, ResumeTimer: _KPCO_Resume}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := Critical("Off")
	Suspend(false)
	OnError(_KPCO_OnError)
	try _KPCO_Exercise()
	catch Any as Failure
		Primary := IsObject(_KPCO.Failure) ? _KPCO.Failure : Failure
	finally {
		for Timer in [_KPCO.TransitionTimer, _KPCO.PauseTimer, _KPCO.ResumeTimer]
			try SetTimer(Timer, 0)
		OnError(_KPCO_OnError, 0)
		Suspend(PreviousSuspend)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_KPCO.Failure)
		Primary := _KPCO.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS clipboard-provenance-owner " . _KPCO.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_KPCO_Main()
