; tests/fixtures/metrics/roi_context_word_owner_body.ahk
; Actual public ROI chars, MF context transitions and canonical candidate append.
#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\roi_encryption_epoch_cutpoint.ahk

_KRCTX_Main() {
	global _KSD
	KL_Roi_SetCanonicalPolicyKnown(true)
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	Mode := A_Args[1]
	if SubStr(Mode, 1, 6) == "epoch-"
		return _KRCTX_EpochMain(Mode)
	if SubStr(Mode, 1, 7) == "policy-"
		return _KRCTX_PolicyMain(Mode)
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

_KRCTX_PolicyMain(Mode) {
	global KL_ENC_Enabled
	MetricsFilters.encrypt := false, KL_ENC_Enabled := false
	A := {App: "fixture-roi-a.exe", Title: "Fixture public ROI A", Hwnd: 401}
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The real context owner must admit the typing fixture.")
	Loop 4
		KL_Roi_OnChar("oldword ")
	KL_Roi_OnChar("frag")
	KL_Roi_OnHotstring("oldtrigger", 3)
	_KSD_Require(KLRoi.word_counts.Get("oldword", 0) == 4 && KLRoi.current_word == "frag"
		&& KLRoi.trigger_last_use.Count == 1, "The actual owners must hold real pre-transition text.")
	_KSD_Require(KL_AppendLog(Map("type", "new_trigger_candidate", "word", "pending-secret", "app", A.App)),
		"The actual central writer must admit the earlier OFF row.")
	Request := KL_Roi_BeginEncryptionRequest(true)
	_KSD_Require(IsObject(Request), "The request must own its transition before any preference can publish.")
	MetricsFilters.encrypt := Mode == "policy-unknown" ? "unknown" : true
	_KSD_Require(KLRoi.current_word == "" && KLRoi.word_counts.Count == 0 && KLRoi.trigger_last_use.Count == 0,
		"The idle request must clear all textual ROI memories without needing another key.")
	Loop 5 {
		KL_Roi_OnChar("hiddenword ")
		KL_Roi_ProcessWord("directword")
	}
	Loop 9
		KL_Roi_OnHotstring("private-trigger", 7, true)
	_KSD_Require(KLRoi.session_fired_count == 10 && KLRoi.session_saved_chars == 66,
		"Real private/public hotstring savings remain numeric under the text prohibition.")
	_KSD_Require(KLRoi.current_word == "" && KLRoi.word_counts.Count == 0 && KLRoi.trigger_last_use.Count == 0,
		"Neither callback nor direct word producer may reconstruct encrypted text.")
	for Kind in ["new_trigger_candidate", "trigger_halflife"]
		_KSD_Require(!KL_AppendLog(Map("type", Kind, "word", "blocked-secret", "app", A.App)),
			"The genuine central queue must refuse direct textual ROI publication.")
	Numeric := 0
	for Row in Keystats._pending_entries {
		_KSD_Require(!KL_Roi_IsTextEntry(Row), "No textual row may remain pending after ON.")
		if Row["type"] == "roi_snapshot"
			Numeric += 1
	}
	_KSD_Require(Numeric == 1, "The genuine periodic numeric snapshot retains its ordinary privacy/context gates.")
	if Mode == "policy-resume"
		MetricsFilters.encrypt := false
	KL_Roi_EndEncryptionRequest(Request)
	if Mode == "policy-resume" {
		Loop 5
			KL_Roi_OnChar("freshword ")
		_KSD_Require(KLRoi.word_counts.Get("freshword", 0) == 5 && !KLRoi.word_counts.Has("oldword")
			&& !KLRoi.word_counts.Has("fragfreshword"), "Only fresh OFF words may resume after a clean request refusal.")
	}
	FileAppend("RECEIPT roi-encryption-capture mode=" . Mode . " numeric=" . Numeric
		. " saved=" . KLRoi.session_saved_chars . " fired=" . KLRoi.session_fired_count . "`n", "*", "UTF-8")
}

_KRCTX_EpochMain(Mode) {
	global _KSD, KL_ENC_Enabled
	MetricsFilters.encrypt := false, KL_ENC_Enabled := false
	A := {App: "fixture-roi-a.exe", Title: "Fixture public ROI A", Hwnd: 401}
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The genuine focus owner must admit the producer.")
	if Mode == "epoch-word-sink"
		Loop 4
			KL_Roi_ProcessWord("oldword")
	if Mode == "epoch-key"
		KL_Roi_OnChar("oldword")
	BeforeEpoch := KLRoiPrivacy.epoch
	State := _KRECP_Install(Mode == "epoch-word-sink" ? 3 : 1,
		Mode == "epoch-key" ? KL_Roi_OnChar.Bind("freshword") : 0)
	try {
		switch Mode {
			case "epoch-char": KL_Roi_OnChar("oldword")
			case "epoch-word", "epoch-word-sink": KL_Roi_ProcessWord("oldword")
			case "epoch-hotstring": KL_Roi_OnHotstring("oldtrigger", 7)
			case "epoch-key": KL_Roi_OnKey(0x08)
			default: throw Error("Unknown producer epoch cutpoint.")
		}
	} finally _KRECP_Restore(State)
	_KSD_Require(State.Calls == 1 && KLRoiPrivacy.epoch == BeforeEpoch + 1
		&& !KLRoiPrivacy.blocked, "A real ON request and clean OFF settlement must occur at the selected read.")
	_KSD_Require(KLRoi.current_word == (Mode == "epoch-key" ? "freshword" : "")
		&& KLRoi.word_counts.Count == 0 && KLRoi.trigger_last_use.Count == 0
		&& Keystats._pending_entries.Length == 0, "An interrupted old producer cannot mutate or publish after OFF resumes.")
	_KSD_Require(KLRoi.session_fired_count == (Mode == "epoch-hotstring" ? 1 : 0)
		&& KLRoi.session_saved_chars == (Mode == "epoch-hotstring" ? 7 : 0),
		"Epoch retirement must preserve the real numeric savings.")
	_KSD_Require(_KSD.Errors == 0, "No hidden production dependency error can qualify an epoch assertion.")
	FileAppend("RECEIPT roi-encryption-epoch mode=" . Mode . " cuts=" . State.Calls
		. " epoch=" . KLRoiPrivacy.epoch . "`n", "*", "UTF-8")
}

if A_Args.Length != 2 || !(A_Args[1] == "same-app" || A_Args[1] == "cross-app" || A_Args[1] == "same-context-refresh"
	|| A_Args[1] == "cross-window" || A_Args[1] == "cross-title" || A_Args[1] == "synthetic-gap"
	|| SubStr(A_Args[1], 1, 6) == "epoch-" || A_Args[1] == "policy-on" || A_Args[1] == "policy-unknown" || A_Args[1] == "policy-resume")
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
