; tests/unit/test_native_editor_completion.ahk

; ==============================================================================
; MODULE: Native editor completion regressions
; DESCRIPTION:
; Exercises the actual TextSend owner with a controlled native boundary. Worker
; preparation, effect verification and canonical completion are distinct events.
; No test sends keyboard input or touches the clipboard.
; ==============================================================================

_NEC_Fixture() {
	State := { Trace: [], Phase: 1, Callbacks: 0, Ok: false, Message: "",
		Current: true, Scheduled: 0, Closed: 0, Owner: 0, CloseBusy: false }
	Port := Map("focus", () => Map("hwnd", 11, "control", 12, "pid", 13),
		"begin", (Owner) => (State.Owner := Owner, State.Trace.Push("begin"), 0),
		"poll", (Token) => Map("phase", State.Phase, "os_error", 1460),
		"decide", (Token, Commit) => (State.Trace.Push("decide:" . Commit), 0),
		"close", (Token) => (State.Closed += 1, State.CloseBusy ? 5 : 0),
		"schedule", (Fn) => (State.Scheduled := Fn))
	Opts := Map("mode", "native", "native_port", Port,
		"erase_before", 3, "deleted_text", "ct★",
		"admission", () => State.Current,
		"atomic_prepare", () => (State.Trace.Push("prepare"), 19),
		"atomic_journal", (Token) => (AssertEqual(19, Token), State.Trace.Push("journal"), true),
		"atomic_commit", () => (State.Trace.Push("commit"), 0),
		"commit_failure", (Message) => (State.Trace.Push("recover"), 0))
	Complete(Ok, Message) {
		State.Callbacks += 1
		State.Ok := Ok
		State.Message := Message
		State.Trace.Push("callback")
	}
	State.Opts := Opts
	State.Complete := Complete
	return State
}

_NEC_Run(Scenario) {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL, _TEXT_CLIPBOARD_QUEUE
	SavedOwner := _TEXT_NATIVE_OWNER
	SavedSerial := _TEXT_NATIVE_SERIAL
	QueueLength := _TEXT_CLIPBOARD_QUEUE.Length
	State := _NEC_Fixture()
	_TEXT_NATIVE_OWNER := 0
	try {
		TextSend("c’était", State.Opts, State.Complete)
		AssertTrue(IsObject(_TEXT_NATIVE_OWNER), "TextSend must queue the actual native owner")
		AssertEqual(0, State.Callbacks, "queued preparation is not completion")
		State.Scheduled.Call()
		AssertEqual("prepare|begin", _TSCS_Join(State.Trace), "start must not publish state")
		AssertEqual(0, State.Callbacks, "worker startup cannot acknowledge output")
		State.Phase := 2
		if Scenario == "stale-ready"
			State.Current := false
		State.Scheduled.Call()
		AssertEqual(0, State.Callbacks, "a ready/committed worker is still pending")
		AssertEqual(Scenario == "stale-ready" ? "decide:0" : "decide:1", State.Trace[3],
			"final admission chooses exactly one commit or cancellation")
		if Scenario == "stale-finish"
			State.Current := false
		State.Phase := Scenario == "unknown" ? 6 : Scenario == "stale-ready" ? 5 : 4
		if Scenario == "live-thread" {
			State.CloseBusy := true
			State.Scheduled.Call()
			AssertEqual(0, State.Callbacks, "storage cannot settle while its worker is live")
			AssertTrue(_TEXT_NATIVE_OWNER == State.Owner, "the live job keeps its exact owner")
			State.CloseBusy := false
		}
		State.Scheduled.Call()
		AssertEqual(1, State.Callbacks, "the terminal receipt produces one callback")
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "settled native ownership must be released")
		if Scenario == "unknown" || Scenario == "stale-finish" {
			AssertFalse(State.Ok, "unverified context must not report canonical success")
			AssertEqual("prepare|begin|decide:1|recover|callback", _TSCS_Join(State.Trace),
				"uncertain effect resets mirrors without publishing a success journal")
		} else if Scenario == "stale-ready" {
			AssertFalse(State.Ok, "pre-mutation cancellation must decline output")
			AssertEqual("prepare|begin|decide:0|callback", _TSCS_Join(State.Trace),
				"a refused preparation changes neither journal nor mirrors")
		} else {
			AssertTrue(State.Ok, "verified effect and canonical commit must acknowledge success")
			AssertEqual("prepare|begin|decide:1|journal|commit|callback", _TSCS_Join(State.Trace),
				"only the terminal native effect may publish journal, mirrors and completion")
		}
		_TextSenderPollNative(State.Owner)
		AssertEqual(1, State.Callbacks, "duplicate wake cannot publish twice")
		AssertEqual(QueueLength, _TEXT_CLIPBOARD_QUEUE.Length, "native output never enters the clipboard FIFO")
	} finally {
		_TEXT_NATIVE_OWNER := SavedOwner
		_TEXT_NATIVE_SERIAL := SavedSerial
	}
}

_NEC_MissingDeletedText() {
	global _TEXT_NATIVE_OWNER
	Saved := _TEXT_NATIVE_OWNER
	State := _NEC_Fixture()
	_TEXT_NATIVE_OWNER := 0
	try {
		State.Opts.Delete("deleted_text")
		TextSend("c’était", State.Opts, State.Complete)
		AssertEqual(1, State.Callbacks, "missing deletion evidence must fail immediately")
		AssertFalse(State.Ok)
		AssertEqual("callback", _TSCS_Join(State.Trace), "invalid erasure must not launch a worker")
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER))
	} finally _TEXT_NATIVE_OWNER := Saved
}

Test("TextSender: native verification precedes completion (native-editor-owner)", _NEC_Run.Bind("success"))
Test("TextSender: native ready admission can be cancelled (native-editor-owner)", _NEC_Run.Bind("stale-ready"))
Test("TextSender: native indeterminate effects reset mirrors without retry (native-editor-owner)", _NEC_Run.Bind("unknown"))
Test("TextSender: native completion cannot overwrite newer input context (native-editor-owner)", _NEC_Run.Bind("stale-finish"))
Test("TextSender: native thread exit precedes resource release (native-editor-owner)", _NEC_Run.Bind("live-thread"))
Test("TextSender: native erasure requires exact deleted text (native-editor-owner)", _NEC_MissingDeletedText)


/** Counts an independently recorded boundary without emulating native settlement. */
_NEC_TraceCount(State, Entry) {
	Count := 0
	for Recorded in State.Trace {
		if Recorded == Entry
			Count += 1
	}
	return Count
}

/** Drives actual fault presentation separately from actual cleanup-debt retirement. */
_NEC_TransportFault(Kind) {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "fault fixture requires an idle native owner")
	Saved := { Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL }
	State := _NEC_Fixture()
	State.Polls := 0
	State.Decisions := 0
	State.RecoveryCalls := 0
	State.Fault := Error("recorded native " . Kind . " refusal")
	State.CloseBusy := true
	State.Phase := Kind == "decide" ? 2 : Kind == "close" ? 4 : 1
	Port := State.Opts["native_port"]
	Port["poll"] := _Poll
	Port["decide"] := _Decide
	Port["close"] := _Close
	State.Opts["commit_failure"] := _Recover
	try {
		TextSend("c’était", State.Opts, State.Complete)
		State.Scheduled.Call()
		AssertEqual(1, State.Callbacks, "first transport fault completes the caller once")
		AssertFalse(State.Ok, "an unavailable native receipt cannot report success")
		AssertEqual(1, State.RecoveryCalls, "first fault invalidates mirrors once")
		AssertTrue(State.Owner.Faulted, "the exact owner retains its fault")
		AssertTrue(_TEXT_NATIVE_OWNER == State.Owner, "live native debt still blocks a new owner")
		Contender := _NEC_Fixture()
		TextSend("other", Contender.Opts, Contender.Complete)
		AssertEqual(1, Contender.Callbacks, "a contending request is refused synchronously")
		AssertFalse(Contender.Ok)
		AssertEqual("callback", _TSCS_Join(Contender.Trace), "debt refusal cannot start another worker")
		AssertTrue(_TEXT_NATIVE_OWNER == State.Owner, "contender refusal cannot erase debt ownership")
		State.Scheduled.Call()
		AssertEqual(1, State.Polls, "faulted cleanup does not reuse a failing poll transport")
		AssertEqual(1, State.Callbacks, "BUSY cleanup cannot present a second failure")
		AssertEqual(1, State.RecoveryCalls, "BUSY cleanup cannot reset mirrors repeatedly")
		State.CloseBusy := false
		State.Scheduled.Call()
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "actual closed receipt retires cleanup ownership")
		AssertEqual(1, State.Callbacks, "retirement cannot publish late success or a second callback")
		AssertFalse(State.Ok)
		AssertEqual(2, State.RecoveryCalls, "terminal retirement invalidates possible late effects")
		AssertEqual(0, _NEC_TraceCount(State, "journal"), "faulted receipts never publish journal rows")
		AssertEqual(0, _NEC_TraceCount(State, "commit"), "faulted receipts never publish canonical success")
		_TextSenderPollNative(State.Owner)
		AssertEqual(1, State.Callbacks, "duplicate wake after retirement remains inert")
	} finally {
		_TEXT_NATIVE_OWNER := Saved.Owner
		_TEXT_NATIVE_SERIAL := Saved.Serial
	}
	_Poll(Token) {
		State.Polls += 1
		if Kind == "poll"
			throw State.Fault
		return Map("phase", State.Phase, "os_error", 0)
	}
	_Decide(Token, Commit) {
		State.Decisions += 1
		throw State.Fault
	}
	_Close(Token) {
		State.Closed += 1
		if Kind == "close" && State.Closed == 1
			throw State.Fault
		return State.CloseBusy ? 5 : 0
	}
	_Recover(Message) {
		State.RecoveryCalls += 1
		State.Trace.Push("recover")
		return 0
	}
}

/** Makes the real focus call reenter queue admission before the outer publish. */
_NEC_ReentrantFocus() {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "reentrant fixture requires idle native ownership")
	Saved := { Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL }
	Outer := _NEC_Fixture()
	Nested := _NEC_Fixture()
	Outer.Opts["native_port"]["focus"] := _Focus
	try {
		TextSend("outer", Outer.Opts, Outer.Complete)
		AssertEqual(1, Outer.Callbacks, "reentered admission refuses the stale outer queue")
		AssertFalse(Outer.Ok)
		AssertEqual(0, Nested.Callbacks, "the actual first published owner remains pending")
		AssertTrue(IsObject(_TEXT_NATIVE_OWNER), "the nested request keeps its owner")
		Nested.Phase := 5
		Nested.Scheduled.Call()
		AssertEqual(1, Nested.Callbacks, "the preserved owner can retire normally")
		AssertFalse(Nested.Ok)
		AssertEqual("prepare|begin|callback", _TSCS_Join(Nested.Trace), "outer refusal cannot replace nested worker state")
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER))
	} finally {
		_TEXT_NATIVE_OWNER := Saved.Owner
		_TEXT_NATIVE_SERIAL := Saved.Serial
	}
	_Focus() {
		TextSend("nested", Nested.Opts, Nested.Complete)
		return Map("hwnd", 11, "control", 12, "pid", 13)
	}
}

Test("TextSender: native poll fault presents failure while retaining cleanup debt (native-editor-owner)", _NEC_TransportFault.Bind("poll"))
Test("TextSender: native decision fault cannot publish late success (native-editor-owner)", _NEC_TransportFault.Bind("decide"))
Test("TextSender: native close fault keeps its owner until confirmed retirement (native-editor-owner)", _NEC_TransportFault.Bind("close"))
Test("TextSender: reentrant focus preserves the first published native owner (native-editor-owner)", _NEC_ReentrantFocus)


/** Exercises genuine canonical recovery owners with only native OS boundaries recorded. */
_NEC_GenericMirrorRecovery(ZeroHook := false) {
	_HNP_Run(_Body)
	_Body() {
		global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL, _LLM_Engine
		global _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
		global _LLM_Bridge_PrefixObserver, _PrefixBuffer, _PrefixContentGeneration
		global _PrefixInputContextGeneration, HSE_Buffer, HSE_StartIsWordBoundary
		global _LSC_LEN, _LSC_CURSOR
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "generic recovery fixture needs idle native ownership")
		Saved := { Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL,
			Engine: _LLM_Engine, Observer: _LLM_Bridge_PrefixObserver,
			Logging: Keylogger.initialized }
		State := _NEC_Fixture()
		State.Opts.Delete("commit_failure")
		if ZeroHook
			State.Opts["commit_failure"] := 0
		try {
			Keylogger.initialized := false
			_LLM_Bridge_PrefixObserver := 0
			_LLM_Engine := Map("inline_last_typed", "obsolete inline")
			_LLM_Bridge_Buffer := "obsolete llm"
			HSE_Buffer := "obsolete hse"
			_PrefixBuffer := "obsolete preview"
			HSE_StartIsWordBoundary := true
			_LSCResetFrom(["o", "l", "d"])
			Before := { Llm: _LLM_Bridge_ContentGeneration,
				Content: _PrefixContentGeneration, Context: _PrefixInputContextGeneration }
			TextSend("c’était", State.Opts, State.Complete)
			State.Scheduled.Call()
			State.Phase := 6
			State.Scheduled.Call()
			AssertEqual(1, State.Callbacks, "unknown output completes with one refusal")
			AssertFalse(State.Ok)
			AssertEqual("", _LLM_Bridge_Buffer, "the actual LLM buffer cannot describe unknown text")
			AssertEqual("", _LLM_Engine["inline_last_typed"], "the actual inline mirror is invalidated")
			AssertEqual("", HSE_Buffer, "the actual HSE feed reset clears its mirror")
			AssertFalse(HSE_StartIsWordBoundary, "unknown text cannot claim a known boundary")
			AssertEqual("", _PrefixBuffer, "the actual prefix commit clears preview state")
			AssertEqual(0, _LSC_LEN, "the actual sent-character ring is reset")
			AssertEqual(0, _LSC_CURSOR)
			AssertEqual(Before.Llm + 1, _LLM_Bridge_ContentGeneration, "recovery revokes old LLM admission")
			AssertEqual(Before.Content + 1, _PrefixContentGeneration, "recovery revokes old prefix content")
			AssertEqual(Before.Context + 1, _PrefixInputContextGeneration, "recovery revokes old input context")
			AssertEqual(0, _NEC_TraceCount(State, "journal"), "unknown output cannot publish a journal row")
			AssertEqual(0, _NEC_TraceCount(State, "commit"), "unknown output cannot publish canonical success")
			AssertFalse(IsObject(_TEXT_NATIVE_OWNER))
		} finally {
			_TEXT_NATIVE_OWNER := Saved.Owner
			_TEXT_NATIVE_SERIAL := Saved.Serial
			_LLM_Engine := Saved.Engine
			_LLM_Bridge_PrefixObserver := Saved.Observer
			Keylogger.initialized := Saved.Logging
		}
	}
}

Test("TextSender: absent recovery hook resets the real canonical mirrors (native-editor-owner)", _NEC_GenericMirrorRecovery.Bind(false))
Test("TextSender: explicit zero recovery hook resets the real canonical mirrors (native-editor-owner)", _NEC_GenericMirrorRecovery.Bind(true))

/** Malformed explicit recovery is not a silent no-op or a successful cleanup. */
_NEC_InvalidRecoveryHook() {
	PreviousCritical := Critical(17)
	Thrown := 0
	try {
		try _TextSenderNativeRecover({Opts: Map("commit_failure", "not callable")}, "unknown")
		catch as Err
			Thrown := Err
		AssertTrue(Type(Thrown) == "TypeError", "malformed recovery must retain its typed refusal")
		AssertEqual("native editor recovery must be callable", Thrown.Message)
		AssertEqual(17, A_IsCritical, "validation refusal preserves the caller Critical interval")
	} finally Critical(PreviousCritical)
}

Test("TextSender: malformed native recovery is a typed refusal (native-editor-owner)", _NEC_InvalidRecoveryHook)
