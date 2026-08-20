; tests/unit/test_text_sender_completion_status.ahk

; ============================================================================== 
; MODULE: TextSender success-aware completion contract test
; DESCRIPTION:
; A failed direct send must report `(false, error)` to its completion callback.
; LLM callers use that status to preserve suggestions/context instead of logging
; a successful acceptance whose text never reached the foreground application.
; ============================================================================== 

#Requires AutoHotkey v2.0

_TSCS_FailingDirectSend(*) {
    throw Error("injected sender failure")
}

_TSCS_ReportsFailedDirectOutput() {
    global _AHK_SendText
    Previous := _AHK_SendText
    SeenOk := true
    SeenError := ""
    try {
        _AHK_SendText := _TSCS_FailingDirectSend
        TextSend("prediction", Map("mode", "direct"), (Ok, ErrorMessage) => (
            SeenOk := Ok,
            SeenError := ErrorMessage
        ))
        AssertEqual(false, SeenOk, "TextSend must report false when direct SendText throws")
        Assert(InStr(SeenError, "injected sender failure") > 0,
            "TextSend must forward the direct-send failure message to its completion callback")
    } finally {
        _AHK_SendText := Previous
    }
}

Test("TextSender: direct injection failure is reported through completion status",
    _TSCS_ReportsFailedDirectOutput)





; =====================================================
; =====================================================
; ======= 2/ Atomic LLM output contract ===============
; =====================================================
; =====================================================

global _TSCS_Trace := []
global _TSCS_AdmissionResult := true
global _TSCS_AtomicOk := false
global _TSCS_AtomicError := ""

_TSCS_Admission() {
	global _TSCS_Trace, _TSCS_AdmissionResult
	_TSCS_Trace.Push("admit:" . (A_IsCritical ? "critical" : "open"))
	return _TSCS_AdmissionResult
}

_TSCS_InputSend(Keys) {
	global _TSCS_Trace
	_TSCS_Trace.Push("send:" . (A_IsCritical ? "critical:" : "open:") . Keys)
}

_TSCS_Prepare() {
	global _TSCS_Trace
	_TSCS_Trace.Push("prepare:" . (A_IsCritical ? "critical" : "open"))
	return Map("token", 1)
}

_TSCS_Journal(Token) {
	global _TSCS_Trace
	AssertTrue(Token is Map, "the prepared journal token must reach commit")
	_TSCS_Trace.Push("journal:" . (A_IsCritical ? "critical" : "open"))
	return true
}

_TSCS_ThrowingJournal(Token) {
	global _TSCS_Trace
	_TSCS_Trace.Push("journal-throws:" . (A_IsCritical ? "critical" : "open"))
	throw Error("injected journal failure")
}

_TSCS_Commit() {
	global _TSCS_Trace
	_TSCS_Trace.Push("commit:" . (A_IsCritical ? "critical" : "open"))
	return _TSCS_Finalize
}

_TSCS_Finalize() {
	global _TSCS_Trace
	_TSCS_Trace.Push("finish:" . (A_IsCritical ? "critical" : "open"))
}

_TSCS_Complete(Ok, ErrorMessage) {
	global _TSCS_Trace, _TSCS_AtomicOk, _TSCS_AtomicError
	_TSCS_AtomicOk := Ok
	_TSCS_AtomicError := ErrorMessage
	_TSCS_Trace.Push("callback:" . (A_IsCritical ? "critical" : "open"))
}

_TSCS_ThrowingCommit() {
	global _TSCS_Trace
	_TSCS_Trace.Push("commit-throws:" . (A_IsCritical ? "critical" : "open"))
	throw Error("injected commit failure")
}

_TSCS_CommitFailure(ErrorMessage) {
	global _TSCS_Trace
	_TSCS_Trace.Push("recover:" . (A_IsCritical ? "critical" : "open")
		. ":" . ErrorMessage)
	return _TSCS_RecoveryFinalize
}

_TSCS_RecoveryFinalize() {
	global _TSCS_Trace
	_TSCS_Trace.Push("recover-finish:" . (A_IsCritical ? "critical" : "open"))
}

_TSCS_ResetAtomic() {
	global _TSCS_Trace, _TSCS_AdmissionResult
	global _TSCS_AtomicOk, _TSCS_AtomicError
	_TSCS_Trace := []
	_TSCS_AdmissionResult := true
	_TSCS_AtomicOk := false
	_TSCS_AtomicError := ""
}

_TSCS_AtomicDirectUsesInputAndCommitsBeforeReopening() {
	global _AHK_SendText, _AHK_SendInput, _TSCS_Trace
	global _TSCS_AtomicOk, _TSCS_AtomicError
	PreviousText := _AHK_SendText
	PreviousInput := _AHK_SendInput
	try {
		_TSCS_ResetAtomic()
		_AHK_SendText := _TSCS_FailingDirectSend
		_AHK_SendInput := _TSCS_InputSend
		TextSend("prediction", Map(
			"mode", "direct",
			"atomic_input", true,
			"admission", _TSCS_Admission,
			"atomic_prepare", _TSCS_Prepare,
			"atomic_journal", _TSCS_Journal,
			"atomic_commit", _TSCS_Commit
		), _TSCS_Complete)
		AssertTrue(_TSCS_AtomicOk, "successful SendInput text must report output present")
		AssertEqual("", _TSCS_AtomicError, "successful atomic output must have no error")
		AssertEqual("prepare:open|admit:critical|send:critical:{Text}prediction|journal:critical|commit:critical|finish:open|callback:open",
			_TSCS_Join(_TSCS_Trace),
			"yielding preparation must stay open; admission, SendInput, journal and RAM commit must be adjacent under Critical; effects and callback must run after it")
	} finally {
		_AHK_SendText := PreviousText
		_AHK_SendInput := PreviousInput
	}
}

_TSCS_Join(Parts) {
	Out := ""
	for Index, Part in Parts
		Out .= (Index == 1 ? "" : "|") . Part
	return Out
}

Test("TextSender: atomic direct LLM output uses one SendInput transaction (llm-output-atomicity)",
	_TSCS_AtomicDirectUsesInputAndCommitsBeforeReopening)

_TSCS_StaleAdmissionEmitsAndCommitsNothing() {
	global _AHK_SendInput, _TSCS_Trace, _TSCS_AdmissionResult
	global _TSCS_AtomicOk, _TSCS_AtomicError
	PreviousInput := _AHK_SendInput
	try {
		_TSCS_ResetAtomic()
		_TSCS_AdmissionResult := false
		_AHK_SendInput := _TSCS_InputSend
		TextSend("stale", Map(
			"mode", "direct",
			"atomic_input", true,
			"admission", _TSCS_Admission,
			"atomic_prepare", _TSCS_Prepare,
			"atomic_journal", _TSCS_Journal,
			"atomic_commit", _TSCS_Commit
		), _TSCS_Complete)
		AssertFalse(_TSCS_AtomicOk, "rejected admission must report output absent")
		Assert(InStr(_TSCS_AtomicError, "admission rejected") > 0,
			"the callback must explain the fail-closed rejection")
		AssertEqual("prepare:open|admit:critical|callback:open", _TSCS_Join(_TSCS_Trace),
			"a stale ticket may prepare fail-closed telemetry but must run neither OS output, journal publication nor state commit")
	} finally {
		_AHK_SendInput := PreviousInput
	}
}

Test("TextSender: stale atomic admission emits no output and no state (llm-output-atomicity)",
	_TSCS_StaleAdmissionEmitsAndCommitsNothing)

_TSCS_PostEmitCommitFailureCannotBecomeRetryable() {
	global _AHK_SendInput, _TSCS_Trace, _TSCS_AtomicOk, _TSCS_AtomicError
	PreviousInput := _AHK_SendInput
	try {
		_TSCS_ResetAtomic()
		_AHK_SendInput := _TSCS_InputSend
		TextSend("visible", Map(
			"mode", "direct",
			"atomic_input", true,
			"admission", _TSCS_Admission,
			"atomic_prepare", _TSCS_Prepare,
			"atomic_journal", _TSCS_Journal,
			"atomic_commit", _TSCS_ThrowingCommit,
			"commit_failure", _TSCS_CommitFailure
		), _TSCS_Complete)
		AssertTrue(_TSCS_AtomicOk,
			"a commit exception after SendInput must never claim visible output was absent")
		Assert(InStr(_TSCS_AtomicError, "state commit failed") > 0,
			"post-output damage must be surfaced distinctly from a send failure")
		AssertEqual("prepare:open|admit:critical|send:critical:{Text}visible|journal:critical|commit-throws:critical|recover:critical:injected commit failure|recover-finish:open|callback:open",
			_TSCS_Join(_TSCS_Trace),
			"the durable journal must survive later mirror damage; RAM recovery closes the transaction before physical input resumes and completion remains non-retryable")
	} finally {
		_AHK_SendInput := PreviousInput
	}
}

Test("TextSender: post-emit commit failure is terminal, never retryable (llm-output-atomicity)",
	_TSCS_PostEmitCommitFailureCannotBecomeRetryable)

_TSCS_PostEmitJournalFailureStillCommitsState() {
	global _AHK_SendInput, _TSCS_Trace, _TSCS_AtomicOk, _TSCS_AtomicError
	PreviousInput := _AHK_SendInput
	try {
		_TSCS_ResetAtomic()
		_AHK_SendInput := _TSCS_InputSend
		TextSend("visible", Map(
			"mode", "direct",
			"atomic_input", true,
			"admission", _TSCS_Admission,
			"atomic_prepare", _TSCS_Prepare,
			"atomic_journal", _TSCS_ThrowingJournal,
			"atomic_commit", _TSCS_Commit
		), _TSCS_Complete)
		AssertTrue(_TSCS_AtomicOk,
			"a journal exception after SendInput must never make visible output retryable")
		Assert(InStr(_TSCS_AtomicError, "journal commit failed") > 0,
			"the completion must surface canonical telemetry damage")
		AssertEqual("prepare:open|admit:critical|send:critical:{Text}visible|journal-throws:critical|commit:critical|finish:open|callback:open",
			_TSCS_Join(_TSCS_Trace),
			"journal failure must not skip the independent RAM mirror commit")
	} finally {
		_AHK_SendInput := PreviousInput
	}
}

Test("TextSender: post-emit journal failure remains non-retryable and commits mirrors (llm-output-atomicity)",
	_TSCS_PostEmitJournalFailureStillCommitsState)

_TSCS_AtomicInputFlagIsStrictlyTyped() {
	global _AHK_SendInput, _TSCS_Trace, _TSCS_AtomicOk, _TSCS_AtomicError
	PreviousInput := _AHK_SendInput
	try {
		_TSCS_ResetAtomic()
		_AHK_SendInput := _TSCS_InputSend
		TextSend("unsafe", Map(
			"mode", "direct",
			"atomic_input", "1",
			"admission", _TSCS_Admission,
			"atomic_commit", _TSCS_Commit
		), _TSCS_Complete)
		AssertFalse(_TSCS_AtomicOk,
			"a numeric-looking string must not enable the private atomic SendInput path")
		Assert(InStr(_TSCS_AtomicError, "requires SendInput") > 0,
			"the malformed private option must fail closed with an actionable error")
		AssertEqual("callback:open", _TSCS_Join(_TSCS_Trace),
			"invalid atomic_input must reach neither admission, OS output nor RAM commit")
	} finally {
		_AHK_SendInput := PreviousInput
	}
}

Test("TextSender: atomic_input rejects numeric-looking strings (llm-output-atomicity)",
	_TSCS_AtomicInputFlagIsStrictlyTyped)

_TSCS_ClipboardForwardsPostCommitDamageAsNonRetryable() {
	Body := _DriverFuncBody("_TextSendClipboard")
	RunPos := InStr(Body, "_TextSenderRunAtomicOutput(")
	CopyPos := InStr(Body, "CompletionError := Result.ErrorMessage", true, RunPos)
	CallbackPos := InStr(Body,
		"_TextSenderInvokeCallback(Callback, true, CompletionError)", true, CopyPos)
	Assert(RunPos > 0 and CopyPos > RunPos and CallbackPos > CopyPos,
		"clipboard mode must preserve a post-emission commit warning through its success callback; dropping it reports recovered state damage as a clean acceptance and diverges from direct mode")
}

Test("TextSender: clipboard preserves non-retryable commit damage (llm-output-atomicity)",
	_TSCS_ClipboardForwardsPostCommitDamageAsNonRetryable)
