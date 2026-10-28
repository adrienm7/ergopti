; tests/fixtures/clipboard_paste_burst_owner_body.ahk

; Genuine MF acquisition and hook projection may legitimately lag each other.
; Refused clipboard rows must not count as admitted public paste activity.
; No OS clipboard read/write, fake append, private cache assignment or ring poke.
#Requires AutoHotkey v2.0

_KCPB_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerInfo(*) {
}
LoggerWarn(*) => _KCPB_Diagnostic()
LoggerError(*) => _KCPB_Diagnostic()
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
_KCPB_Diagnostic() {
	global _KCPB
	_KCPB.Diagnostics += 1
}

_KCPB_Acquire(Timeout) {
	global _KCPB
	_KCPB.Acquisitions += 1
	Frame := _KCPB.NativeFrame
	return {ok: true, hwnd: Frame.Hwnd, process_name: Frame.App, title: Frame.Title, class: "Edit"}
}

_KCPB_MFFocus(Frame) {
	global _KCPB
	_KCPB.NativeFrame := Frame
	_KCPB_Require(MF_RefreshFocus(true, _KCPB_Acquire), "The real MF owner must publish the acquired frame.")
	Snapshot := MF_GetFocusSnapshot()
	_KCPB_Require(Snapshot.valid && Snapshot.hwnd == Frame.Hwnd
		&& Snapshot.process_name == Frame.App, "The genuine MF snapshot must match the supplied identity.")
	return Snapshot
}

_KCPB_Focus(Frame) {
	_KCPB_MFFocus(Frame)
	_KCPB_Require(!Keystats._flush_in_progress && Keystats._retry_snapshots.Length == 0
		&& Keystats.buffer_events.Length == 0 && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
		"Real hook refresh must reach its genuine empty-buffer branch.")
	_KCPB_Require(KL_Hook_RefreshContext(true) && Keystats.session_app == Frame.App
		&& Keystats.session_title == Frame.Title, "The genuine hook must project the acquired context.")
}

; Scheduling is controlled at the genuine focus acquisition port. Its captured
; HWND is delegated unchanged, not a claim that GetForegroundWindow pumps.
KL_FocusedHostHwnd() {
	global _KCPB
	Captured := _KCPB.NativeFrame.Hwnd
	_KCPB.FocusReads += 1
	if !_KCPB.Armed
		return Captured
	_KCPB.Armed := false
	try {
		_KCPB_Require(!A_IsCritical && !A_IsSuspended, "The real privacy callout must start interruptible and running.")
		SetTimer(_KCPB.PauseTimer, -1)
		Started := A_TickCount
		while !_KCPB.PauseDone && TickElapsed(Started) < 2000
			Sleep(10)
		_KCPB_Require(_KCPB.PauseDone && _KCPB.TimerCalls == 1 && A_IsSuspended,
			"The genuine pause timer must settle before returning the captured HWND.")
	} catch Any as Failure {
		if !IsObject(_KCPB.Failure)
			_KCPB.Failure := Failure
	}
	return Captured
}

KL_DetectPasswordCheap(Hwnd, &Conclusive) {
	global _KCPB
	_KCPB_Require(Hwnd == _KCPB.PublicA.Hwnd || Hwnd == _KCPB.PrivateB.Hwnd || Hwnd == _KCPB.PublicC.Hwnd,
		"Every actual password classification must use one known acquired HWND.")
	Conclusive := true
	return false
}
KL_SchedulePasswordDetect(*) {
	throw Error("Conclusive native-port Edit results must not request an unrelated UIA worker.")
}

_KCPB_Pause() {
	global _KCPB
	try {
		_KCPB_Require(!A_IsCritical && !A_IsSuspended, "The timer must interrupt an eligible live handler.")
		_KCPB.TimerCalls += 1
		Suspend(true)
		_KCPB.PauseObserved := A_IsSuspended
		_KCPB_Require(_KCPB.PauseObserved, "Native Suspend must actually become active.")
	} catch Any as Failure {
		if !IsObject(_KCPB.Failure)
			_KCPB.Failure := Failure
	} finally {
		_KCPB.PauseDone := true
	}
}

_KCPB_Rows(Type) {
	Rows := []
	for Entry in Keystats._pending_entries
		if Entry["type"] == Type
			Rows.Push(Entry)
	return Rows
}

_KCPB_CheckErrors() {
	global _KCPB
	if IsObject(_KCPB.Failure)
		throw _KCPB.Failure
	_KCPB_Require(_KCPB.Diagnostics == 0, "A swallowed classifier error cannot qualify a refused paste.")
}

_KCPB_Observe(Phase) {
	global _KCPB, _KL_CLIP_FILTER_PROBE
	FileAppend("RECEIPT clipboard-paste-burst-owner mode=" . _KCPB.Mode . " phase=" . Phase
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " root=" . A_Args[2]
		. " pastes=" . _KCPB_Rows("clipboard_paste").Length . " bursts=" . _KCPB_Rows("paste_burst").Length
		. " ticks=" . KLClip.paste_ticks.Length . " ticks_at_refusal=" . _KCPB.TicksAtRefusal
		. " pastes_at_refusal=" . _KCPB.PastesAtRefusal . " privacy_delta=" . _KCPB.PrivacyDelta
		. " timer_calls=" . _KCPB.TimerCalls . " paused_observed=" . _KCPB.PauseObserved
		. " resumed=" . _KCPB.Resumed . " armed=" . _KCPB.Armed
		. " app=" . Keystats.session_app . " mf_app=" . MF_GetFocusSnapshot().process_name
		. " elapsed=" . TickElapsed(_KCPB.WindowStarted) . " filter_probe_default=" . (_KL_CLIP_FILTER_PROBE == 0)
		. "`n", "*", "UTF-8-RAW")
	FileAppend("QUEUE clipboard-paste-burst-owner " . Phase . " "
		. KL_JsonEncode(Keystats._pending_entries) . "`n", "*", "UTF-8-RAW")
}

_KCPB_Exercise() {
	global _KCPB, _KL_CLIP_FILTER_PROBE
	_KCPB_Require(_KL_CLIP_FILTER_PROBE == 0 && !KLPasswordCache.focus_tracking_active,
		"The default real MF/privacy path must run without fabricated focus-cache permission.")
	Keystats.initialized := true
	MetricsFilters.disabled_apps := Map(_KCPB.PrivateB.App, true)
	_KCPB_Focus(_KCPB.Mode == "private-lag" ? _KCPB.PrivateB : _KCPB.PublicA)
	_KCPB_Require(KLClip.paste_ticks.Length == 0 && _KCPB_Rows("clipboard_paste").Length == 0,
		"The isolated child must start with no paste activity.")
	_KCPB.WindowStarted := A_TickCount
	if _KCPB.Mode != "current" {
		if _KCPB.Mode == "private-lag" {
			_KCPB_MFFocus(_KCPB.PublicC)
			_KCPB_Require(Keystats.session_app == _KCPB.PrivateB.App && !MF_ShouldFilter()
				&& MF_ShouldFilterFor(Keystats.session_app, Keystats.session_title),
				"Real MF C may lead the still-excluded hook B; only genuine owner APIs establish this lag.")
		} else if _KCPB.Mode == "pause-probe" {
			_KCPB.Armed := true
		} else {
			throw Error("Unknown private fixture mode")
		}
		Hits := Keystats.health_privacy_hits
		KL_Clip_OnPaste()
		_KCPB_CheckErrors()
		_KCPB.PastesAtRefusal := _KCPB_Rows("clipboard_paste").Length
		_KCPB.TicksAtRefusal := KLClip.paste_ticks.Length
		_KCPB.PrivacyDelta := Keystats.health_privacy_hits - Hits
		_KCPB_Require(_KCPB.PastesAtRefusal == 0 && _KCPB_Rows("paste_burst").Length == 0,
			"The genuine central sink must refuse the initial attempt before public threshold assertions.")
		if _KCPB.Mode == "private-lag" {
			_KCPB_Require(_KCPB.PrivacyDelta == 1 && !A_IsSuspended
				&& Keystats.session_app == _KCPB.PrivateB.App
				&& MF_GetFocusSnapshot().process_name == _KCPB.PublicC.App,
				"The initial refusal must be the real outgoing-payload privacy policy, not an error or pause.")
		} else {
			_KCPB_Require(_KCPB.PauseObserved && _KCPB.PauseDone && _KCPB.TimerCalls == 1
				&& !_KCPB.Armed && A_IsSuspended && _KCPB.PrivacyDelta == 0,
				"The eligible native timer must revoke this exact producer before its central admission.")
			Suspend(false)
			_KCPB.Resumed := !A_IsSuspended
			_KCPB_Require(_KCPB.Resumed, "The actual native resume must precede later public activity.")
		}
		_KCPB_Observe("refused")
	}
	_KCPB_Focus(_KCPB.PublicC)
	_KCPB_CheckErrors()
	loop 4 {
		KL_Clip_OnPaste()
		_KCPB_CheckErrors()
	}
	_KCPB_Require(TickElapsed(_KCPB.WindowStarted) < KLClipConst.PASTE_BURST_WINDOW_MS,
		"All actual attempts must fit in the genuine burst window; expiry is not a business failure.")
	_KCPB_Observe("four-public")
	_KCPB_Require(_KCPB_Rows("clipboard_paste").Length == 4,
		"Four later public attempts must reach four actual canonical paste rows.")
	_KCPB_Require(_KCPB_Rows("paste_burst").Length == 0,
		"A refused initial paste cannot count toward the first public burst.")
	_KCPB_Require(KLClip.paste_ticks.Length == 4, "Exactly four admitted public pastes must remain accumulated.")
	KL_Clip_OnPaste()
	_KCPB_CheckErrors()
	_KCPB_Require(TickElapsed(_KCPB.WindowStarted) < KLClipConst.PASTE_BURST_WINDOW_MS,
		"The fifth admitted paste must still lie in the same actual burst window.")
	_KCPB_Observe("complete")
	Pastes := _KCPB_Rows("clipboard_paste"), Bursts := _KCPB_Rows("paste_burst")
	_KCPB_Require(Pastes.Length == 5 && Bursts.Length == 1 && KLClip.paste_ticks.Length == 0,
		"The fifth genuinely admitted public paste must emit one burst and retire its ring.")
	_KCPB_Require(Bursts[1]["count"] == 5 && Bursts[1]["app"] == _KCPB.PublicC.App
		&& Bursts[1]["window_ms"] == KLClipConst.PASTE_BURST_WINDOW_MS,
		"The actual burst must describe only those five admitted public pastes.")
	for Entry in Pastes
		_KCPB_Require(Entry["app"] == _KCPB.PublicC.App && Entry["source_app"] == ""
			&& Entry["char_count"] == 0 && Entry["copy_lag_ms"] == -1,
			"Every accepted row must have the true public target and untouched unknown copy provenance.")
}

_KCPB_OnError(Failure, *) {
	global _KCPB
	if !IsObject(_KCPB.Failure)
		_KCPB.Failure := Failure
	return true
}

_KCPB_Main() {
	global _KCPB
	if A_Args.Length != 2
		ExitApp(2)
	_KCPB := {Mode: A_Args[1], PublicA: {Hwnd: 801, App: "burst-public-a.exe", Title: "Burst Public A"},
		PrivateB: {Hwnd: 802, App: "burst-private-b.exe", Title: "Burst Private B"},
		PublicC: {Hwnd: 803, App: "burst-public-c.exe", Title: "Burst Public C"},
		NativeFrame: 0, Failure: 0, Diagnostics: 0, Acquisitions: 0, FocusReads: 0,
		Armed: false, TimerCalls: 0, PauseObserved: false, PauseDone: false, Resumed: false,
		WindowStarted: 0, TicksAtRefusal: -1, PastesAtRefusal: -1, PrivacyDelta: -1,
		PauseTimer: _KCPB_Pause}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := Critical("Off")
	Suspend(false)
	OnError(_KCPB_OnError)
	try _KCPB_Exercise()
	catch Any as Failure
		Primary := IsObject(_KCPB.Failure) ? _KCPB.Failure : Failure
	finally {
		try SetTimer(_KCPB.PauseTimer, 0)
		OnError(_KCPB_OnError, 0)
		Suspend(PreviousSuspend)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_KCPB.Failure)
		Primary := _KCPB.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS clipboard-paste-burst-owner " . _KCPB.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_KCPB_Main()
