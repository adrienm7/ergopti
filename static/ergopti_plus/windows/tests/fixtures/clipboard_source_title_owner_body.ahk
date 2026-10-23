; tests/fixtures/clipboard_source_title_owner_body.ahk

; ==============================================================================
; MODULE: Clipboard Source Title Privacy Child
; DESCRIPTION:
; Publishes real MF snapshots and hook contexts at their distinct refresh
; boundaries, then drives actual clipboard handlers and central append.
; Nontext handler delivery does not touch the OS clipboard or physical input.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCST_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Diagnostics are passive, but any unexpected error rejects the test.
LoggerInfo(*) {
}
LoggerWarn(*) => _KCST_UnexpectedDiagnostic()
LoggerError(*) => _KCST_UnexpectedDiagnostic()
HotPath_Now() => 0
HotPath_LogIfSlow(*) => 0
_KCST_UnexpectedDiagnostic() {
	global _KCST
	_KCST.Diagnostics += 1
}

; These identifiers belong to OS acquisition ports, not actual desktop windows.
_KCST_Acquire(Timeout) {
	global _KCST
	_KCST.Acquisitions += 1
	Frame := _KCST.Frame
	return {ok: true, hwnd: Frame.Hwnd, process_name: Frame.App,
		title: Frame.Title, class: "Edit"}
}
KL_FocusedHostHwnd() {
	global _KCST
	_KCST.FocusReads += 1
	return _KCST.Frame.Hwnd
}
KL_DetectPasswordCheap(Hwnd, &Conclusive) {
	global _KCST
	_KCST.CheapReads += 1
	_KCST_Require(Hwnd == _KCST.A.Hwnd || Hwnd == _KCST.C.Hwnd,
		"The conclusive native Edit port must receive a known controlled identifier.")
	Conclusive := true
	return false
}
KL_SchedulePasswordDetect(*) {
	throw Error("A conclusive native Edit result must not start a UIA worker.")
}

_KCST_Publish(Frame, RefreshHook) {
	global _KCST
	_KCST.Frame := Frame
	_KCST_Require(MF_RefreshFocus(true, _KCST_Acquire),
		"The actual MF producer must admit the complete OS-port snapshot.")
	Snapshot := MF_GetFocusSnapshot()
	_KCST_Require(Snapshot.valid && Snapshot.hwnd == Frame.Hwnd
		&& Snapshot.process_name == Frame.App && Snapshot.title == Frame.Title,
		"The real MF snapshot must contain the exact captured app and title.")
	if RefreshHook {
		_KCST_Require(!Keystats._flush_in_progress && Keystats._retry_snapshots.Length == 0
			&& Keystats.buffer_events.Length == 0 && Keystats.session_clicks == 0 && Keystats.session_scrolls == 0,
			"The genuine hook context refresh must use its empty-buffer branch.")
		_KCST_Require(KL_Hook_RefreshContext(true), "The real hook must project the admitted MF snapshot.")
		_KCST_Require(Keystats.session_app == Frame.App && Keystats.session_title == Frame.Title,
			"Hook context must contain the same source app and title after actual projection.")
	}
	return Snapshot
}

_KCST_Rows(Type) {
	Rows := []
	for Entry in Keystats._pending_entries
		if Entry["type"] == Type
			Rows.Push(Entry)
	return Rows
}

_KCST_Observe(Phase) {
	global _KCST
	FileAppend("RECEIPT clipboard-source-title-owner mode=" . _KCST.Mode . " phase=" . Phase
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " root=" . A_Args[2]
		. " source_policy_refused=" . _KCST.SourceFiltered . " app_only_refused=" . _KCST.AppOnlyFiltered
		. " live_policy_refused=" . _KCST.LiveFiltered . " hook_lag=" . _KCST.HookLag
		. " copies=" . _KCST_Rows("clipboard_copy").Length . " pastes=" . _KCST_Rows("clipboard_paste").Length
		. " copy_app=" . KLClip.last_copy_app . " copy_tick=" . KLClip.last_copy_tick
		. " copy_len=" . KLClip.last_copy_len . " diagnostics=" . _KCST.Diagnostics
		. " acquisitions=" . _KCST.Acquisitions . " focus_reads=" . _KCST.FocusReads
		. " cheap_reads=" . _KCST.CheapReads . "`n", "*", "UTF-8-RAW")
	FileAppend("QUEUE clipboard-source-title-owner " . Phase . " "
		. KL_JsonEncode(Keystats._pending_entries) . "`n", "*", "UTF-8-RAW")
	FileAppend("SNAPSHOTS clipboard-source-title-owner " . Phase . " "
		. KL_JsonEncode(Map("source_a", Map("app", _KCST.SnapshotA.process_name, "title", _KCST.SnapshotA.title),
			"live", Map("app", MF_GetFocusSnapshot().process_name, "title", MF_GetFocusSnapshot().title),
			"hook", Map("app", Keystats.session_app, "title", Keystats.session_title))) . "`n", "*", "UTF-8-RAW")
}

_KCST_Exercise() {
	global _KCST, _KL_CLIP_FILTER_PROBE
	_KCST_Require(_KL_CLIP_FILTER_PROBE == 0 && !KLPasswordCache.focus_tracking_active,
		"The real MF/central privacy path must run without invented focus-hook permission.")
	Keystats.initialized := true
	MetricsFilters.private_browsing := true
	MetricsFilters.disabled_apps := _KCST.Mode == "excluded-app-lag" ? Map(_KCST.A.App, true) : Map()
	_KCST.SnapshotA := _KCST_Publish(_KCST.A, true)
	_KCST.SourceFiltered := MF_ShouldFilterFor(_KCST.A.App, _KCST.A.Title)
	_KCST.AppOnlyFiltered := MF_ShouldFilterFor(_KCST.A.App, "")
	ExpectedRefusal := _KCST.Mode != "public-lag"
	_KCST_Require(_KCST.SourceFiltered == ExpectedRefusal,
		"The real explicit-source privacy predicate must classify A before the business oracle.")
	_KCST_Require(_KCST.AppOnlyFiltered == (_KCST.Mode == "excluded-app-lag"),
		"Only the app-exclusion control may be refused without A's actual title.")
	if _KCST.Mode != "private-title-live" {
		_KCST.SnapshotC := _KCST_Publish(_KCST.C, false)
		_KCST.HookLag := MF_GetFocusSnapshot() == _KCST.SnapshotC
			&& _KCST.SnapshotC != _KCST.SnapshotA && Keystats.session_app == _KCST.A.App
			&& Keystats.session_title == _KCST.A.Title
		_KCST_Require(_KCST.HookLag,
			"Actual MF must advance to public C while the real hook still retains A without private cache writes.")
	}
	_KCST.LiveFiltered := MF_ShouldFilter()
	_KCST_Require(_KCST.LiveFiltered == (_KCST.Mode == "private-title-live"),
		"Live MF must classify C public during lag, or A private in the live control.")
	_KCST_Require(_KCST.Diagnostics == 0 && !IsObject(_KCST.Failure),
		"No missing dependency or swallowed diagnostic may qualify a privacy refusal.")
	_KCST.CopyStarted := A_TickCount
	KL_Clip_OnChange(2)
	_KCST.CopyFinished := A_TickCount
	_KCST_Observe("after-copy")
	_KCST_Require(_KCST.Diagnostics == 0 && !IsObject(_KCST.Failure),
		"The actual clipboard copy must complete without an unexpected diagnostic.")
	Copies := _KCST_Rows("clipboard_copy")
	if ExpectedRefusal {
		_KCST_Require(Copies.Length == 0,
			"The actual clipboard handler must admit zero copy rows for the refused source app/title A.")
		_KCST_Require(KLClip.last_copy_tick == 0 && KLClip.last_copy_len == 0 && KLClip.last_copy_app == "",
			"A refused source must leave exactly unknown copy provenance.")
	} else {
		_KCST_Require(Copies.Length <= 1,
			"One public handler delivery may admit at most one real copy row.")
		if Copies.Length {
			_KCST_Require(Copies[1]["app"] == _KCST.A.App && Copies[1]["char_count"] == 0
				&& Copies[1]["content_type"] == "other" && KLClip.last_copy_app == _KCST.A.App
				&& KLClip.last_copy_len == 0 && KLClip.last_copy_tick >= _KCST.CopyStarted
				&& KLClip.last_copy_tick <= _KCST.CopyFinished,
				"An admitted public copy must retain only the exact public A observation.")
		} else {
			_KCST_Require(KLClip.last_copy_tick == 0 && KLClip.last_copy_len == 0 && KLClip.last_copy_app == "",
				"A conservatively refused public lag must leave exactly unknown provenance.")
		}
	}
	_KCST_Publish(_KCST.C, true)
	_KCST_Require(!MF_ShouldFilter() && !MF_ShouldFilterFor(_KCST.C.App, _KCST.C.Title),
		"The actual paste context must now be genuinely public C in both consumers.")
	KL_Clip_OnPaste()
	_KCST.PasteFinished := A_TickCount
	_KCST_Observe("after-paste")
	_KCST_Require(_KCST.Diagnostics == 0 && !IsObject(_KCST.Failure),
		"The final oracle must not hide an earlier native-boundary or diagnostic failure.")
	Pastes := _KCST_Rows("clipboard_paste")
	_KCST_Require(Pastes.Length == 1 && Pastes[1]["app"] == _KCST.C.App,
		"The actual central queue must contain exactly one public C paste.")
	Paste := Pastes[1]
	if ExpectedRefusal || Copies.Length == 0 {
		_KCST_Require(Paste["source_app"] == "" && Paste["char_count"] == 0 && Paste["copy_lag_ms"] == -1,
			"A later public C paste must carry exactly unknown provenance after a refused source.")
	} else {
		_KCST_Require(Paste["source_app"] == _KCST.A.App && Paste["char_count"] == 0
			&& Paste["copy_lag_ms"] >= 0 && Paste["copy_lag_ms"] <= TickElapsed(_KCST.CopyStarted, _KCST.PasteFinished),
			"A permitted public A lag must remain the same public origin with a coherent age.")
	}
}

_KCST_OnError(Failure, *) {
	global _KCST
	if !IsObject(_KCST.Failure)
		_KCST.Failure := Failure
	return true
}

_KCST_Main() {
	global _KCST
	if A_Args.Length != 2
		ExitApp(2)
	Mode := A_Args[1]
	_KCST := {Mode: Mode, A: {Hwnd: 711, App: "msedge.exe",
		Title: (Mode == "private-title-lag" || Mode == "private-title-live") ? "Private A - InPrivate" : "Public A"},
		C: {Hwnd: 713, App: "public-c.exe", Title: "Public C"}, Frame: 0,
		Failure: 0, Diagnostics: 0, Acquisitions: 0, FocusReads: 0, CheapReads: 0,
		SourceFiltered: false, AppOnlyFiltered: false, LiveFiltered: false, HookLag: false,
		SnapshotA: 0, SnapshotC: 0, CopyStarted: 0, CopyFinished: 0, PasteFinished: 0}
	Primary := 0, PreviousSuspend := A_IsSuspended, PreviousCritical := Critical("Off")
	Suspend(false)
	OnError(_KCST_OnError)
	try _KCST_Exercise()
	catch Any as Failure
		Primary := IsObject(_KCST.Failure) ? _KCST.Failure : Failure
	finally {
		OnError(_KCST_OnError, 0)
		Suspend(PreviousSuspend)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_KCST.Failure)
		Primary := _KCST.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS clipboard-source-title-owner " . _KCST.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_KCST_Main()
