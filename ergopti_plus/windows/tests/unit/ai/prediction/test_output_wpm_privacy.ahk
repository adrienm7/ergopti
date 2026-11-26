; tests/unit/ai/prediction/test_output_wpm_privacy.ahk

; ==============================================================================
; MODULE: AI Output and the WPM Readouts' Privacy (MET-02)
; DESCRIPTION:
; Accepted AI text fed the WPM widget one AI sample per character whatever the
; metrics privacy filter said: in an excluded app, a private window or a secure
; field the journal recorded nothing, yet the Windows pill and tray readout
; sped up and turned the AI colour. Typed and hotstring text, and Linux
; record_synthetic_output, stay silent there. The real journal commit and the
; real RAM commit run in TextSender's order, inside one Critical transaction.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Test harness =======
; ===============================
; ===============================

; Runs Body with an empty record of WPMWidget_Push calls (the suite's stub of
; the widget's producer) and restores the caller's state.
_AWP_WithRing(Body) {
	global _LLM_Bridge_Buffer, _Stub_WpmPushCalls
	Saved := {Calls: _Stub_WpmPushCalls, Buffer: _LLM_Bridge_Buffer}
	try {
		_Stub_WpmPushCalls := []
		Body()
	} finally {
		_Stub_WpmPushCalls := Saved.Calls
		_LLM_Bridge_Buffer := Saved.Buffer
	}
}

; Commits Token, then the injected text, as _TextSenderRunAtomicOutput does.
_AWP_Commit(Transaction, Token) {
	PreviousCritical := Critical("On")
	try {
		Journal := _LLM_Bridge_InjectionOptions(Transaction)["atomic_journal"]
		Journal.Call(Token)
		_LLM_Bridge_CommitInjectedText(Transaction)
	} finally {
		Critical(PreviousCritical)
	}
}

_AWP_Transaction(Text) {
	return {Text: Text, DeletedText: "", Inline: false, SourceControl: 0, Deletes: 0,
		Admission: (*) => true, MetricsRecorded: false}
}





; ========================
; ========================
; ======= 2/ Cases =======
; ========================
; ========================

_AWP_FilteredOutputIsSilent() {
	_AWP_WithRing(_Body)
	_Body() {
		; The token KL_PrepareLlmOutputJournal returns when the privacy filter refuses
		; the focused window: no rows at all.
		Transaction := _AWP_Transaction("abc")
		_AWP_Commit(Transaction, Map("entries", []))
		AssertFalse(Transaction.MetricsRecorded, "a filtered output is not recorded")
		AssertEqual(0, _Stub_WpmPushCalls.Length, "nor counted by the WPM readouts (met-02)")
	}
}
Test("AI output: a privacy-filtered acceptance feeds no WPM sample (met-02)", _AWP_FilteredOutputIsSilent)

_AWP_RecordedOutputIsCounted() {
	_AWP_WithRing(_Body)
	_Body() {
		Transaction := _AWP_Transaction("abcd")
		; The flag is the journal's own answer; the commit reads nothing else.
		Transaction.MetricsRecorded := true
		PreviousCritical := Critical("On")
		try _LLM_Bridge_CommitInjectedText(Transaction)
		finally Critical(PreviousCritical)
		AssertEqual(4, _Stub_WpmPushCalls.Length, "one AI sample per recorded character")
		AssertTrue(_Stub_WpmPushCalls[1].is_ai, "marked AI, for the AI colour")
	}
}
Test("AI output: a recorded acceptance feeds one AI sample per character (met-02)", _AWP_RecordedOutputIsCounted)

_AWP_JournalAnswerSetsTheFlag() {
	Transaction := _AWP_Transaction("x")
	Journal := _LLM_Bridge_InjectionOptions(Transaction)["atomic_journal"]
	PreviousCritical := Critical("On")
	try {
		AssertTrue(Journal.Call(Map("entries", [])) == true, "an empty token commits nothing, successfully")
		AssertFalse(Transaction.MetricsRecorded, "and records nothing")
		AssertFalse(Journal.Call(0) == true, "a missing token is refused")
		AssertFalse(Transaction.MetricsRecorded, "and records nothing")
	} finally {
		Critical(PreviousCritical)
	}
}
Test("AI output: the journal commit tells the transaction whether it recorded (met-02)", _AWP_JournalAnswerSetsTheFlag)
