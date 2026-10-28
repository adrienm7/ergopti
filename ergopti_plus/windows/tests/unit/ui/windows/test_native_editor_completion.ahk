; tests/unit/ui/windows/test_native_editor_completion.ahk

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
			Logging: Keystats.initialized }
		State := _NEC_Fixture()
		State.Opts.Delete("commit_failure")
		if ZeroHook
			State.Opts["commit_failure"] := 0
		try {
			Keystats.initialized := false
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
			Keystats.initialized := Saved.Logging
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


/** Retains an embedded NUL through both literal construction and the real JSON decoder. */
_NEC_NulPayload(Position, FromJson) {
	Left := Position == "head" ? "" : "private_head"
	Right := Position == "tail" ? "" : "private_tail"
	Text := FromJson ? JsonParse('"' . Left . '\u0000' . Right . '"') : Left . Chr(0) . Right
	AssertEqual(StrLen(Left) + 1 + StrLen(Right), StrLen(Text), "the test payload must retain its NUL and full suffix")
	AssertEqual(StrLen(Left), DllCall("Kernel32\lstrlenW", "Ptr", StrPtr(Text), "Int"),
		"the actual WStr ABI truncates this representable AHK string at its NUL")
	AssertEqual(StrLen(Left) + 1 + StrLen(Right), StrLen(Text),
		"the independent const-pointer oracle must not invalidate the payload variable's stored length")
	return Text
}

/** Public admission must refuse before choosing or scheduling a native/clipboard owner. */
_NEC_NulCannotAcquireOutput(Mode, Field, Position, FromJson, WithCallback := true) {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL, _LLM_NavEventOwnerModule
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY, _TextSenderNativeTestPort
	global _AHK_SendText, _AHK_SendInput
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "the NUL fixture requires an idle native owner")
	AssertEqual(0, _TEXT_CLIPBOARD_QUEUE.Length, "the NUL fixture requires an idle clipboard queue")
	AssertFalse(_TEXT_CLIPBOARD_BUSY, "the NUL fixture cannot borrow a live clipboard owner")
	Saved := { Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL, Module: _LLM_NavEventOwnerModule,
		Queue: _TEXT_CLIPBOARD_QUEUE, Busy: _TEXT_CLIPBOARD_BUSY, Port: _TextSenderNativeTestPort,
		SendText: _AHK_SendText, SendInput: _AHK_SendInput,
		WarnCall: LoggerWarn.HasOwnProp("Call") ? LoggerWarn.GetOwnPropDesc("Call") : 0 }
	State := _NEC_Fixture()
	State.Logs := []
	State.FocusCalls := 0
	State.Primitives := 0
	State.Opts["native_port"]["focus"] := () => (State.FocusCalls += 1, Map("hwnd", 11, "control", 12, "pid", 13))
	try {
		LoggerWarn.DefineProp("Call", {Call: (Self, Tag, Message, Values*) =>
			State.Logs.Push({Tag: Tag, Message: Message, Values: Values})})
		_TEXT_CLIPBOARD_QUEUE := []
		; Old code may enqueue this malformed request. Keep its real one-shot
		; wake unable to touch the clipboard until the regression can refuse it.
		_TEXT_CLIPBOARD_BUSY := true
		_TextSenderNativeTestPort := State.Opts["native_port"]
		_AHK_SendText := (*) => (State.Primitives += 1)
		_AHK_SendInput := (*) => (State.Primitives += 1)
		Payload := _NEC_NulPayload(Position, FromJson)
		AssertTrue(RegExMatch(Payload, "\x00") > 0, "the actual public request must still contain its embedded NUL")
		Text := Field == "text" ? Payload : "accepted"
		Options := Mode == "native" ? State.Opts : Map("mode", Mode)
		if Field == "deleted_text" {
			Options["deleted_text"] := Payload
			Options["erase_before"] := StrLen(Payload)
			AssertEqual(StrLen(Payload), _TextCodepointLength(Payload), "ASCII plus NUL owns its full erasure count")
		}
		TextSend(Text, Options, WithCallback ? State.Complete : 0)
		AssertEqual(WithCallback ? 1 : 0, State.Callbacks,
			"unrepresentable text must refuse immediately without inventing an optional completion consumer")
		if WithCallback {
			AssertFalse(State.Ok, "a NUL-terminated output ABI cannot acknowledge the full input")
			AssertTrue(InStr(State.Message, "NUL") > 0, "the generic refusal must explain the unsupported code unit")
			AssertEqual(0, InStr(State.Message, "private_"), "refusal must not disclose the supplied text")
		}
		AssertEqual(1, State.Logs.Length, "the refusal remains observable even without a completion consumer")
		AssertEqual("TextSender", State.Logs[1].Tag)
		AssertTrue(InStr(State.Logs[1].Message, "NUL") > 0, "the warning names the unrepresentable boundary")
		AssertEqual(0, InStr(State.Logs[1].Message, "private_"), "the warning never embeds source text")
		AssertEqual(0, State.Logs[1].Values.Length, "no private output or deletion text reaches logger arguments")
		AssertEqual(WithCallback ? "callback" : "", _TSCS_Join(State.Trace),
			"no preparation, native begin, journal or commit may run")
		AssertEqual(0, State.FocusCalls, "refusal must precede target focus acquisition")
		AssertEqual(0, State.Scheduled, "no native polling timer may be scheduled")
		AssertEqual(0, State.Primitives, "no keyboard output primitive may run")
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "refusal cannot retain a native owner")
		AssertEqual(Saved.Serial, _TEXT_NATIVE_SERIAL, "refusal cannot spend a native worker token")
		AssertEqual(0, _TEXT_CLIPBOARD_QUEUE.Length, "refusal cannot enqueue a clipboard write")
		AssertEqual(Saved.Module, _LLM_NavEventOwnerModule, "refusal cannot load or acquire the native DLL")
	} finally {
		SetTimer(_TextSenderStartClipboard, 0)
		_TEXT_NATIVE_OWNER := Saved.Owner
		_TEXT_NATIVE_SERIAL := Saved.Serial
		_TEXT_CLIPBOARD_QUEUE := Saved.Queue
		_TEXT_CLIPBOARD_BUSY := Saved.Busy
		_TextSenderNativeTestPort := Saved.Port
		_AHK_SendText := Saved.SendText
		_AHK_SendInput := Saved.SendInput
		if IsObject(Saved.WarnCall)
			LoggerWarn.DefineProp("Call", Saved.WarnCall)
		else
			LoggerWarn.DeleteProp("Call")
	}
}
for _NEC_NulMode in ["native", "direct", "clipboard", "auto"] {
	for _NEC_NulPosition in ["head", "middle", "tail"] {
		for _NEC_NulJson in [false, true]
			Test("TextSender: " . _NEC_NulMode . " rejects " . _NEC_NulPosition . " NUL text from "
				. (_NEC_NulJson ? "JSON" : "literal") . " before dispatch (text-native-nul-admission)",
				_NEC_NulCannotAcquireOutput.Bind(_NEC_NulMode, "text", _NEC_NulPosition, _NEC_NulJson))
	}
}
for _NEC_NulPosition in ["head", "middle", "tail"] {
	for _NEC_NulJson in [false, true]
		Test("TextSender: native rejects " . _NEC_NulPosition . " NUL deletion from "
			. (_NEC_NulJson ? "JSON" : "literal") . " before dispatch (text-native-nul-admission)",
			_NEC_NulCannotAcquireOutput.Bind("native", "deleted_text", _NEC_NulPosition, _NEC_NulJson))
}


/** Legal Unicode remains complete through admission, dispatch and terminal settlement. */
_NEC_NulGuardPreservesLegalNativeText(Text, Deleted) {
	global _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "the legal-text control requires an idle native owner")
	Saved := { Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL }
	State := _NEC_Fixture()
	try {
		State.Opts["deleted_text"] := Deleted
		State.Opts["erase_before"] := _TextCodepointLength(Deleted)
		AssertEqual(StrLen(Text), DllCall("Kernel32\lstrlenW", "Ptr", StrPtr(Text), "Int"), "legal output fits the actual WStr ABI")
		AssertEqual(StrLen(Deleted), DllCall("Kernel32\lstrlenW", "Ptr", StrPtr(Deleted), "Int"), "legal deletion fits the actual WStr ABI")
		TextSend(Text, State.Opts, State.Complete)
		AssertEqual(0, State.Callbacks, "legal native output must retain its asynchronous completion contract")
		AssertTrue(IsObject(_TEXT_NATIVE_OWNER), "legal empty or Unicode output still acquires an owner")
		AssertEqual(Text, _TEXT_NATIVE_OWNER.Text, "the complete Unicode output is retained without normalization")
		AssertEqual(Deleted, _TEXT_NATIVE_OWNER.Opts["deleted_text"], "the exact Unicode deletion evidence survives admission")
		State.Scheduled.Call()
		State.Phase := 2
		State.Scheduled.Call()
		State.Phase := 4
		State.Scheduled.Call()
		AssertEqual(1, State.Callbacks)
		AssertTrue(State.Ok, "only the usual terminal receipt settles the legal request")
		AssertEqual("prepare|begin|decide:1|journal|commit|callback", _TSCS_Join(State.Trace))
		AssertFalse(IsObject(_TEXT_NATIVE_OWNER))
	} finally {
		_TEXT_NATIVE_OWNER := Saved.Owner
		_TEXT_NATIVE_SERIAL := Saved.Serial
	}
}
for _NEC_LegalCase in [
	{ Name: "empty", Text: "", Deleted: "" },
	{ Name: "numeric string", Text: "0", Deleted: "" },
	{ Name: "non-ASCII and supplementary scalar", Text: Chr(0xE9) . Chr(0x1F642), Deleted: Chr(0x1F642) . Chr(0xE9) },
	{ Name: "legal whitespace", Text: "`t`r`n", Deleted: "`n" }
]
	Test("TextSender: " . _NEC_LegalCase.Name . " remains native-admissible (text-native-nul-admission)",
		_NEC_NulGuardPreservesLegalNativeText.Bind(_NEC_LegalCase.Text, _NEC_LegalCase.Deleted))


Test("TextSender: NUL refusal without a completion callback remains observable (text-native-nul-admission)",
	_NEC_NulCannotAcquireOutput.Bind("native", "text", "middle", true, false))

_NEC_CapsWordAdmission(Mode) {
	global CapsWordEnabled, _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	AssertFalse(CapsWordAutoOff.Armed is Map, "The output fixture must own an idle CapsWord activation")
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "The output fixture must own an idle native sender")
	Saved := {Enabled: CapsWordEnabled, Configured: CapsWordAutoOff.Configured,
		Subscribers: HookDispatcher._subscribers, Critical: A_IsCritical, Suspended: A_IsSuspended,
		Owner: _TEXT_NATIVE_OWNER, Serial: _TEXT_NATIVE_SERIAL}
	State := _NEC_Fixture()
	State.Ends := []
	Accepted := Mode == "accepted-delimiter" || Mode == "accepted-word"
	Text := Mode == "accepted-word" ? "word" : "word "
	try {
		Critical("Off"), Suspend(false)
		HookDispatcher._subscribers := Map()
		Pointer := Map()
		for Kind in CapsWordAutoOffPointerKinds()
			Pointer[Kind] := 0
		Policy := CapsWordAutoOffCompile(Map("idle_timeout_seconds", 0,
			"terminators", ["space"], "pointer", Pointer), CapsWordAutoOffPointerKinds(), &Reason)
		AssertTrue(Policy is Map, "The actual CapsWord policy must compile: " . Reason)
		CapsWordAutoOff.Configured := Policy
		CapsWordEnabled := true
		AssertTrue(CapsWordAutoOffArm(_CWAOO_End.Bind(State, "output")))
		if Mode == "missing-evidence"
			State.Opts.Delete("deleted_text")
		else if Mode == "mismatched-evidence"
			State.Opts["deleted_text"] := "x"
		else if Mode == "unowned-evidence"
			State.Opts["erase_before"] := 0
		else if Mode == "busy"
			_TEXT_NATIVE_OWNER := {Token: "existing"}
		else if Mode == "focus-refused"
			State.Opts["native_port"]["focus"] := _Refuse
		else if Mode == "schedule-refused"
			State.Opts["native_port"]["schedule"] := _Refuse
		else
			AssertTrue(Accepted, "The fixture mode must be explicit")
		TextSend(Text, State.Opts, State.Complete)
		if !Accepted {
			AssertEqual(1, State.Callbacks, "The actual native admission must refuse synchronously")
			AssertFalse(State.Ok, "A refused native request must report failure")
			AssertTrue(State.Message != "", "A refused request must retain a concrete failure")
			AssertEqual("callback", _TSCS_Join(State.Trace), "Refusal must perform no preparation, native begin, journal or commit")
			_TestPrint("# native-refusal-capsword mode=" . Mode . " callback_ok=" . State.Ok
				. " native_effects=" . _TSCS_Join(State.Trace) . " capsword=" . CapsWordEnabled . " ends=" . State.Ends.Length)
			AssertTrue(CapsWordEnabled, "A request that never queued output must leave CapsWord active")
			AssertEqual(0, State.Ends.Length, "A native refusal must not report an output delimiter")
			AssertTrue(CapsWordAutoOff.Armed == Policy, "The actual armed policy remains owned")
			if Mode == "busy"
				AssertEqual("existing", _TEXT_NATIVE_OWNER.Token, "Refusal must retain the prior output owner")
			else
				AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "Refused admission must leave no output owner")
		} else {
			AssertEqual(0, State.Callbacks, "A real queued request is still pending")
			AssertTrue(IsObject(_TEXT_NATIVE_OWNER), "The accepted request must acquire its actual native owner")
			AssertEqual(Mode == "accepted-word", CapsWordEnabled, "Queued output keeps the existing delimiter policy")
			AssertEqual(Mode == "accepted-word" ? 0 : 1, State.Ends.Length)
			State.Scheduled.Call()
			State.Phase := 2
			State.Scheduled.Call()
			State.Phase := 4
			State.Scheduled.Call()
			AssertEqual(1, State.Callbacks)
			AssertTrue(State.Ok, "The accepted control must settle successfully")
			AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "The accepted control must retire its native owner")
			AssertEqual(Mode == "accepted-word" ? 0 : 1, State.Ends.Length, "Completion must not duplicate the output delimiter")
		}
	} finally {
		CapsWordAutoOffDisarm()
		HookDispatcher._subscribers := Saved.Subscribers
		CapsWordEnabled := Saved.Enabled, CapsWordAutoOff.Configured := Saved.Configured
		_TEXT_NATIVE_OWNER := Saved.Owner, _TEXT_NATIVE_SERIAL := Saved.Serial
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
	_Refuse(*) {
		throw Error("Recorded native admission refusal")
	}
}

for _NEC_CapsWordMode in ["missing-evidence", "mismatched-evidence", "unowned-evidence", "busy",
	"focus-refused", "schedule-refused", "accepted-delimiter", "accepted-word"]
	Test("TextSend native CapsWord: " . _NEC_CapsWordMode . " respects queue admission (native-refusal-capsword)",
		_NEC_CapsWordAdmission.Bind(_NEC_CapsWordMode))
