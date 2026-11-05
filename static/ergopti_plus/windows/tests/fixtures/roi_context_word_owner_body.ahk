; tests/fixtures/roi_context_word_owner_body.ahk
; Actual public ROI chars, MF context transitions and canonical candidate append.
#Requires AutoHotkey v2.0

_KRCTX_Main() {
	global _KSD
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	Mode := A_Args[1]
	Changed := Mode != "same-app" && Mode != "same-context-refresh"
	AppChanged := Mode == "cross-app"
	A := {App: "fixture-roi-a.exe", Title: "Fixture public ROI A", Hwnd: 401}
	B := {App: "fixture-roi-b.exe", Title: "Fixture public ROI B", Hwnd: 402}
	if Mode == "cross-window"
		B := {App: A.App, Title: A.Title, Hwnd: 402}
	else if Mode == "cross-title"
		B := {App: A.App, Title: "Fixture public ROI B", Hwnd: A.Hwnd}
	else if Mode == "same-context-refresh"
		B := A
	Loop KLRoiConst.REPEAT_THRESHOLD {
		_KSD_Acquire(A)
		_KSD_Require(KL_Hook_RefreshContext(true), "The actual public A focus must publish.")
		for Char in ["a", "b", "c"]
			KL_Roi_OnChar(Char)
		_KSD_Require(KLRoi.current_word == "abc", "The real accepted scalar chars must form the first fragment.")
		if Mode == "synthetic-gap" {
			; The real marker interrupts continuity even if SendInput generates no InputHook callbacks.
			SyntheticOwner := KL_MarkSynthetic("fixture-output-gap", false)
			_KSD_Require(KL_ClearSynthetic(SyntheticOwner), "The actual synthetic owner must retire.")
		} else if Changed || Mode == "same-context-refresh" {
			_KSD_Acquire(B)
			_KSD_Require(KL_Hook_RefreshContext(true), "The actual mouse-like context transition contains no fabricated delimiter key.")
		}
		for Char in ["d", "e", "f", " "]
			KL_Roi_OnChar(Char)
	}
	Candidates := []
	for Row in Keystats._pending_entries
		if Row["type"] == "new_trigger_candidate"
			Candidates.Push(Row)
	Count := KLRoi.word_counts.Get("abcdef", 0)
	FileAppend("RECEIPT roi-context-owner mode=" . Mode . " changed_app=" . AppChanged . " changed_context=" . Changed . " compound_count=" . Count
		. " candidate_rows=" . Candidates.Length . " map_size=" . KLRoi.word_counts.Count
		. " probes=" . _KSD.Probes . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "Real context and append prerequisites cannot hide an error.")
	_KSD_Require(Keystats.session_app == (AppChanged ? B.App : A.App), "The actual context owner must finish in the expected application.")
	_KSD_Require(Count == (Changed ? 0 : KLRoiConst.REPEAT_THRESHOLD),
		"ROI must never count a word assembled from two independent typing contexts.")
	_KSD_Require(Candidates.Length == (Changed ? 0 : 1),
		"Only a complete manually typed same-context word may emit a canonical trigger candidate.")
	if !Changed
		_KSD_Require(Candidates[1]["word"] == "abcdef" && Candidates[1]["occurrences"] == KLRoiConst.REPEAT_THRESHOLD
			&& Candidates[1]["app"] == A.App, "The genuine control must retain its candidate text, frequency and application.")
}

if A_Args.Length != 2 || !(A_Args[1] == "same-app" || A_Args[1] == "cross-app" || A_Args[1] == "same-context-refresh"
	|| A_Args[1] == "cross-window" || A_Args[1] == "cross-title" || A_Args[1] == "synthetic-gap")
	throw Error("The private ROI context case needs an exact mode and owned directory.")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
try {
	_KRCTX_Main()
	FileAppend("PASS roi-context-owner " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KRCTX_EntryFailure {
	FileAppend("FAIL roi-context-owner " . _KRCTX_EntryFailure.Message . " [" . _KRCTX_EntryFailure.File . ":" . _KRCTX_EntryFailure.Line . "]`n", "*", "UTF-8")
	if FileExist(_KSD.Log)
		FileAppend(FileRead(_KSD.Log, "UTF-8"), "*", "UTF-8")
	ExitApp(1)
} finally Keystats.initialized := false
