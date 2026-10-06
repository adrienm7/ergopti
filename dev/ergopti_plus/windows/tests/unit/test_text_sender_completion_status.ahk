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

; =======================================================
; =======================================================
; ======= 3/ Clipboard injection metadata ==============
; =======================================================
; =======================================================

_TSCD_State() {
	return Map("hwnd", 41, "pid", 73, "process_name", "Notepad.exe",
		"window_class", "Notepad", "control_class", "RichEditD2DPT1",
		"logical", 1, "physical", 0, "sequence", 19, "clipboard_units", 50,
		"observed_tick", 4294967800,
		"clipboard_plaintext", "PRIVATE CLIPBOARD CONTENT")
}

_TSCD_RecordInfo(Records, Tag, Message, Args*) {
	Records.Push({ Tag: Tag, Message: Format(Message, Args*), Args: Args })
}

_TSCD_RecordStage(Stage, Emitted := -1, EraseCount := 16) {
	Records := []
	_TextSenderClipboardDiagnostic(Stage, 50, EraseCount, 7, 18, Emitted,
		_TSCD_State, _TSCD_RecordInfo.Bind(Records))
	return Records
}

_TSCD_MetadataCounts() {
	Records := _TSCD_RecordStage("write-ready")
	AssertEqual(1, Records.Length, "one stage emits one metadata record")
	AssertEqual("TextSender", Records[1].Tag, "the central component owns the record")
	Assert(InStr(Records[1].Message, "payload_units=50, erase_before=16") > 0,
		"the reported replacement must distinguish deletion from insertion")
	Assert(InStr(Records[1].Message, "generation=7, owned_sequence=18, current_sequence=19") > 0,
		"the record must preserve the observed and owned clipboard identities separately")
	Assert(InStr(Records[1].Message, "observed_tick=4294967800") > 0,
		"native monotonic observations must retain their full width")
}

Test("TextSender: clipboard diagnostics retain incident erase and payload counts (clipboard-output-diagnostics)",
	_TSCD_MetadataCounts)

_TSCD_TargetModifiers() {
	Records := _TSCD_RecordStage("write-ready")
	Assert(InStr(Records[1].Message, "hwnd=41, pid=73, process_name=Notepad.exe") > 0,
		"target identity must be available without document titles")
	Assert(InStr(Records[1].Message, "window_class=Notepad, control_class=RichEditD2DPT1") > 0,
		"the receiving control metadata must remain distinct from the top-level window")
	Assert(InStr(Records[1].Message, "logical_modifiers=1, physical_modifiers=0") > 0,
		"a logical Ctrl must not be reported as physically held")
}

Test("TextSender: clipboard diagnostics preserve target and separate modifier states (clipboard-output-diagnostics)",
	_TSCD_TargetModifiers)

_TSCD_PrivacyAndEmission() {
	Records := _TSCD_RecordStage("send-returned", true)
	Assert(InStr(Records[1].Message, "PRIVATE CLIPBOARD CONTENT") == 0,
		"unused reader fields must never leak into the log")
	Assert(InStr(Records[1].Message, "clipboard_units=50, primitive_returned=1") > 0,
		"the observed length and native primitive return are metadata only")
	Assert(InStr(Records[1].Message, "success") == 0,
		"native primitive return must not claim successful application processing")
}

Test("TextSender: clipboard diagnostics omit clipboard content and do not claim app acknowledgement (clipboard-output-diagnostics)",
	_TSCD_PrivacyAndEmission)

_TSCD_Stages() {
	Pending := _TSCD_RecordStage("write-ready")
	Refused := _TSCD_RecordStage("send-refused", false)
	Insertion := _TSCD_RecordStage("send-returned", true, 0)
	Assert(InStr(Pending[1].Message, "primitive_returned=-1") > 0,
		"an unattempted output must not claim an emitted primitive")
	Assert(InStr(Refused[1].Message, "primitive_returned=0") > 0,
		"a refused output must preserve its absent emission")
	Assert(InStr(Insertion[1].Message, "erase_before=0") > 0,
		"insertion-only comparison must report zero deletions")
}

Test("TextSender: clipboard diagnostics distinguish pending refused and insertion stages (clipboard-output-diagnostics)",
	_TSCD_Stages)

_TSCD_OwnerRouting() {
	Body := _DriverFuncBody("_TextSendClipboard")
	Atomic := _DriverFuncBody("_TextSenderRunAtomicOutput")
	Diagnostic := _DriverFuncBody("_TextSenderClipboardDiagnostic")
	Assert(Body != "" and Atomic != "" and Diagnostic != "",
		"all actual owners are required subjects")
	Code := _DriverMaskNonCode(&Body)
	AtomicCode := _DriverMaskNonCode(&Atomic)
	DiagnosticCode := _DriverMaskNonCode(&Diagnostic)
	Guard := RegExMatch(Code, "i)\bif\s*\(\s*Generation\s*!=\s*_TEXT_CLIPBOARD_GENERATION\s*\)")
	Write := RegExMatch(Code, "i)\bCB_Write\s*\(")
	Ready := RegExMatch(Code, "i)\b_TextSenderTryClipboardDiagnostic\s*\(")
	Send := RegExMatch(Code, "i)\b_TextSenderRunAtomicOutput\s*\(")
	Assert(Ready > 0 and Guard > Ready and Send > Guard,
		"yielding diagnostic work must precede the final clipboard and admission checks")
	Assert(Write > 0 and Ready > Write,
		"diagnostics must not introduce a yield between the entry pause guard and clipboard write")
	Assert(InStr(AtomicCode, "ClipboardDiagnostic") == 0,
		"the atomic output owner must contain no new diagnostic native probes or logger calls")
	Assert(RegExMatch(DiagnosticCode, "i)\bTimerFn\s*:=\s*SetTimer\b") > 0,
		"the default diagnostic timer must still resolve the real timer at call time")
}

Test("TextSender: clipboard diagnostics remain before final guards and outside the atomic owner (clipboard-output-diagnostics)",
	_TSCD_OwnerRouting)

_TSCD_ReadState(Observation) {
	Observation.Reads += 1
	return _TSCD_State()
}

_TSCD_CaptureTimer(Observation, Callback, Period) {
	Observation.Callbacks.Push(Callback)
	Observation.Periods.Push(Period)
}

_TSCD_CriticalDeferral() {
	Observation := { Reads: 0, Callbacks: [], Periods: [] }
	Records := []
	PreviousCritical := Critical(17)
	try {
		_TextSenderClipboardDiagnostic("write-ready", 50, 16, 7, 18, -1,
			_TSCD_ReadState.Bind(Observation), _TSCD_RecordInfo.Bind(Records),
			_TSCD_CaptureTimer.Bind(Observation))
		AssertEqual(17, A_IsCritical, "diagnostics must preserve the caller's exact Critical interval")
		AssertEqual(0, Observation.Reads, "no native observation may occur on the Critical caller")
		AssertEqual(0, Records.Length, "no log sink may run on the Critical caller")
		AssertEqual(1, Observation.Callbacks.Length, "one deferred callback must be retained")
		AssertEqual(-1, Observation.Periods[1], "deferral must remain one-shot")
		Critical("Off")
		Observation.Callbacks[1].Call()
		AssertEqual(1, Observation.Reads, "the captured callback must observe once after Critical ends")
		AssertEqual(1, Records.Length, "the captured callback must emit exactly one metadata log")
	} finally {
		Critical(PreviousCritical)
	}
}

Test("TextSender: clipboard diagnostics defer native reads and logs under caller Critical (clipboard-output-diagnostics)",
	_TSCD_CriticalDeferral)

_TSCT_CentralTransitions() {
	global LOGGER_MIN_LEVEL, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, _LOGGER_PATH_DATE
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _LOGGER_REPEAT_ENABLED, _LOGGER_REPEAT_STREAKS, _LOGGER_REPEAT_DATE
	global _LOGGER_REPEAT_OLDEST, _LOGGER_REPEAT_SEQ, _LOGGER_REPEAT_USE
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_TEST_SINK
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	Saved := _TLOG_CaptureLoggerState()
	Extra := { PathDate: _LOGGER_PATH_DATE, RepeatEnabled: _LOGGER_REPEAT_ENABLED,
		Streaks: _LOGGER_REPEAT_STREAKS, RepeatDate: _LOGGER_REPEAT_DATE,
		Oldest: _LOGGER_REPEAT_OLDEST, Seq: _LOGGER_REPEAT_SEQ, Use: _LOGGER_REPEAT_USE,
		Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN, Sink: _LOGGER_TEST_SINK }
	Lines := []
	try {
		LOGGER_MIN_LEVEL := "INFO"
		_LoggerRefreshFastFlags()
		LOGGER_LOG_PATH := ""
		LOGGER_ERRORS_LOG_PATH := ""
		_LOGGER_PATH_DATE := ""
		_LOGGER_SUB_PATHS := Map()
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_LEVEL := ""
		_LOGGER_DEDUP_COUNT := 0
		_LastErrTime := 0
		_LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := () => 1000
		_LOGGER_STAMP_FN := () => "2026-10-04 20:15:30:000"
		LoggerSetTestSink((Line) => Lines.Push(Line))
		_LoggerRepeatEnable()
		Stages := [
			["write-ready", 7, -1], ["send-returned", 7, true],
			["restore-owner-pending", 7, -1], ["restore-owner-settled", 7, -1],
			["write-ready", 8, -1], ["send-returned", 8, true],
			["restore-owner-settled", 8, -1]
		]
		for Stage in Stages
			_TextSenderClipboardDiagnostic(Stage[1], 40, 13, Stage[2], 4910, Stage[3], _TSCD_State)
		AssertEqual(7, Lines.Length,
			"the real armed central repeat collapser must publish every stage and generation immediately")
		AssertEqual(7, LOGGER_RING_BUFFER.Length,
			"the same transition evidence must reach the real logger ring")
		for Index, Stage in Stages {
			AssertContains(Lines[Index], "[INFO] [TextSender] Clipboard injection " . Stage[1] . ":",
				"the central sink must preserve stage order")
			AssertContains(Lines[Index], "generation=" . Stage[2] . ",",
				"a later generation must remain distinguishable within the repeat window")
			AssertContains(Lines[Index], "payload_units=40, erase_before=13",
				"the real formatter must retain the incident's deletion and payload counts")
		}
	} finally {
		_LOGGER_REPEAT_ENABLED := Extra.RepeatEnabled
		_LOGGER_REPEAT_STREAKS := Extra.Streaks
		_LOGGER_REPEAT_DATE := Extra.RepeatDate
		_LOGGER_REPEAT_OLDEST := Extra.Oldest
		_LOGGER_REPEAT_SEQ := Extra.Seq
		_LOGGER_REPEAT_USE := Extra.Use
		_LOGGER_CLOCK_FN := Extra.Clock
		_LOGGER_STAMP_FN := Extra.Stamp
		_LOGGER_TEST_SINK := Extra.Sink
		_LOGGER_PATH_DATE := Extra.PathDate
		_TLOG_RestoreLoggerState(Saved)
	}
}

Test("TextSender: real central logger preserves clipboard transitions and generations (clipboard-diagnostic-transitions)",
	_TSCT_CentralTransitions)

_TSCT_FocusedControlClass() {
	Body := _DriverFuncBody("_TextSenderReadClipboardDiagnosticState")
	Assert(Body != "", "the actual native diagnostic reader must exist")
	Code := _DriverMaskNonCode(&Body)
	Assert(RegExMatch(Code, "i)\bFocusedControlHwnd\s*:=\s*Hwnd\s*\?\s*ControlGetFocus\s*\(") > 0,
		"ControlGetFocus returns a HWND and must be captured as that identity")
	Assert(RegExMatch(Code,
		"im)\bControlClass\s*:=\s*FocusedControlHwnd\s*\?\s*WinGetClass\s*\(\s*FocusedControlHwnd\s*\)\s*:\s*$") > 0,
		"the control class must be queried from the exact captured HWND; zero has no class")
}

Test("TextSender: clipboard diagnostics resolve a focused HWND to its actual class (clipboard-diagnostic-transitions)",
	_TSCT_FocusedControlClass)
