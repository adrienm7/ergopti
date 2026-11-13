; tests/fixtures/core/context_roi_stale_owner_body.ahk

; Real focus owner and ROI fragment; timer is a scheduling port, not physical focus.
#Requires AutoHotkey v2.0
_KRSC_Timer() {
	global _KRSC
	try {
		_KSD_Require(!A_IsCritical && _KRSC.GetterWaiting, "The real timer must interrupt the retained B getter")
		_KRSC.TimerCalls += 1
		_KRSC.Current := _KSD_Acquire(_KRSC.C)
		_KSD_Require(_KRSC.Current != _KRSC.BSnapshot && !MF_ShouldFilter(),
			"The current C must be a distinct public focus before input")
		KL_Roi_OnChar("c")
		_KSD_Require(KLRoi.current_word == "c" && KLRoi.word_context == _KRSC.Current,
			"The actual ROI producer must first own a C fragment")
	} catch Any as Failure
		_KRSC.Failure := Failure
	finally _KRSC.TimerDone := true
}
_KRSC_Getter() {
	global _KRSC
	Snapshot := MF_GetFocusSnapshot()
	_KSD_Require(Snapshot == _KRSC.BSnapshot && Snapshot.valid && !A_IsCritical,
		"The real getter must retain the acquired public B object")
	_KRSC.GetterWaiting := true
	SetTimer(_KRSC_Timer, -1)
	Start := A_TickCount
	while !_KRSC.TimerDone && TickElapsed64(Start) < 2500
		Sleep(5)
	if IsObject(_KRSC.Failure)
		throw _KRSC.Failure
	_KSD_Require(_KRSC.TimerDone && _KRSC.TimerCalls == 1 && MF_GetFocusSnapshot() == _KRSC.Current,
		"C and its fragment must precede the old getter return")
	return _KRSC.Mode == "current" ? _KRSC.Current : Snapshot
}
_KRSC_Main() {
	global _KRSC, _KSD
	KL_Roi_SetCanonicalPolicyKnown(true)
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	_KRSC.BSnapshot := _KSD_Acquire(_KRSC.B)
	_KSD_Require(!MF_ShouldFilter(), "The source B must be public before input")
	_KSD_Require(KL_Hook_RefreshContext(true), "The real B context must first be established")
	KL_Roi_OnChar("b")
	_KSD_Require(KLRoi.current_word == "b" && KLRoi.word_context == _KRSC.BSnapshot,
		"The real ROI producer must own the initial B fragment")
	if _KRSC.Mode == "legitimate" {
		_KRSC.Current := _KSD_Acquire(_KRSC.C)
		KL_Hook_RefreshContext(true)
		_KSD_Require(KLRoi.current_word == "" && KLRoi.word_context == _KRSC.Current,
			"A genuine B-to-C observation must retire the old B fragment")
		KL_Roi_OnChar("c")
	} else
		KL_Hook_RefreshContext(true, _KRSC_Getter)
	FileAppend("OBSERVATION roi-stale mode=" . _KRSC.Mode . " word=" . KLRoi.current_word
		. " context_c=" . (KLRoi.word_context == _KRSC.Current) . " timers=" . _KRSC.TimerCalls
		. " errors=" . _KSD.Errors . "`n", "*")
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "No dependency error may impersonate ROI loss")
	_KSD_Require(KLRoi.current_word == "c" && KLRoi.word_context == _KRSC.Current,
		"A fragment admitted under current C must survive a stale older getter")
}
if A_Args.Length != 2 || !(A_Args[1] == "stale" || A_Args[1] == "current" || A_Args[1] == "legitimate")
	throw Error("The private ROI probe requires its exact mode and owned directory")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
global _KRSC := {Mode: A_Args[1], B: {App: "fixture-roi-b.exe", Title: "Public ROI B", Hwnd: 1902},
	C: {App: "fixture-roi-c.exe", Title: "Public ROI C", Hwnd: 1903}, BSnapshot: 0, Current: 0,
	GetterWaiting: false, TimerDone: false, TimerCalls: 0, Failure: 0}
try {
	_KRSC_Main()
	FileAppend("PASS roi-stale " . _KRSC.Mode . "`n", "*")
	ExitApp(0)
} catch Any as _KRSC_EntryFailure {
	FileAppend("FAIL roi-stale " . _KRSC_EntryFailure.Message . " [" . _KRSC_EntryFailure.File . ":" . _KRSC_EntryFailure.Line . "]`n", "*")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*")
	ExitApp(1)
} finally {
	SetTimer(_KRSC_Timer, 0)
	Keystats.initialized := false
}
