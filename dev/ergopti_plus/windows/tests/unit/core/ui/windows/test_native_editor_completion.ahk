; tests/unit/core/ui/windows/test_native_editor_completion.ahk

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

; Cross-process receiving checks use the shipped production DLL and actual focus.
; The separate receiver's native subclass observes/delays one real Edit message.
; These are receiving controls, not a new defect or a source-contract substitute.

_NECP_Done(State, Code, Output, ErrorText) {
	State.Calls += 1
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

/** Duplicates the actual pre-adoption process capability without changing launch. */
_NECP_Adopt(State, TaskState, Native) {
	Current := DllCall("Kernel32\GetCurrentProcess", "Ptr")
	Process := 0
	AssertTrue(DllCall("Kernel32\DuplicateHandle", "Ptr", Current,
		"Ptr", Native["ProcessHandle"], "Ptr", Current, "Ptr*", &Process,
		"UInt", 0, "Int", false, "UInt", 2, "Int"), "SETUP: exact receiver handle duplication")
	State.Process := Process, State.Pid := Native["Pid"]
}

_NECP_Event(Name) {
	static CloseDebt := []
	Handle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
		"Int", false, "Str", Name, "Ptr")
	NativeError := A_LastError
	if !Handle
		throw OSError(NativeError, , "SETUP: private editor event creation")
	if NativeError == 183 {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
			CloseDebt.Push(Handle)
		throw Error("SETUP: the event name belongs to an existing owner")
	}
	return Handle
}

_NECP_Exports() {
	global _VendorDir
	Manifest := JsonParse(FSReadUtf8Exact(_VendorDir . "\ergopti_nav_owner.manifest.json"))
	ExpectedHash := Manifest["dll_sha256"]
	Exports := Map()
	for Name in ["Begin", "Poll", "Decide", "Close"]
		Exports[Name] := _LLM_NavEventOwnerNativeExport("ErgoptiEditor_" . Name)
	Module := 0
	AssertTrue(DllCall("Kernel32\GetModuleHandleExW", "UInt", 6,
		"Ptr", Exports["Begin"], "Ptr*", &Module, "Int"), "SETUP: authenticate actual export module")
	Path := Buffer(65536, 0)
	Length := DllCall("Kernel32\GetModuleFileNameW", "Ptr", Module,
		"Ptr", Path, "UInt", 32768, "UInt")
	AssertTrue(Length > 0 && Length < 32768, "SETUP: resolve the actually loaded native DLL")
	ActualHash := CryptoSha256Bytes(FSReadBytesStrict(StrGet(Path, Length, "UTF-16")))
	AssertEqual(StrUpper(ExpectedHash), StrUpper(ActualHash), "SETUP: shipped DLL manifest hash")
	_TestPrint("# native-editor-cross-process authenticated_dll=" . ActualHash)
	return Exports
}

_NECP_WaitFile(State, Path, Boundary) {
	Started := A_TickCount
	while !FileExist(Path) && State.Calls == 0 && TickElapsed(Started) < 5000 {
		_SR_TreePoll()
		Sleep(10)
	}
	AssertTrue(FileExist(Path) != "", Boundary . ": exact receiver receipt missing: "
		. State.Output . State.ErrorText)
}

_NECP_Phase(Exports, Token, Minimum) {
	Started := A_TickCount
	Phase := 0, NativeError := 0
	loop {
		AssertEqual(0, DllCall(Exports["Poll"], "UInt64", Token,
			"UInt*", &Phase, "UInt*", &NativeError, "Int"), "BUSINESS: actual native phase receipt")
		if Phase >= Minimum
			return {Phase: Phase, NativeError: NativeError}
		AssertTrue(TickElapsed(Started) < 5000, "BUSINESS: actual native worker phase timed out")
		_SR_TreePoll()
		Sleep(10)
	}
}

/** A terminal phase alone cannot retire the worker's copied strings. */
_NECP_CloseWorker(State) {
	if !State.WorkerStarted || State.WorkerClosed
		return true
	Started := A_TickCount
	loop {
		Status := DllCall(State.Exports["Close"], "UInt64", State.Token, "Int")
		if Status == 0 {
			State.WorkerClosed := true
			return true
		}
		if Status != 5
			throw Error("RETIREMENT: native editor close returned " . Status)
		if TickElapsed(Started) >= 5000
			return false
		Sleep(10)
	}
}

_NECP_SavedFocus() {
	Window := DllCall("User32\GetForegroundWindow", "Ptr")
	Pid := 0, Control := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Window, "UInt*", &Pid, "UInt")
	Info := Buffer(8 + 6 * A_PtrSize + 16, 0)
	NumPut("UInt", Info.Size, Info)
	if ThreadId && DllCall("User32\GetGUIThreadInfo", "UInt", ThreadId, "Ptr", Info, "Int")
		Control := NumGet(Info, 8 + A_PtrSize, "Ptr")
	return {Window: Window, Control: Control, Pid: Pid}
}

_NECP_RestoreFocus(Saved) {
	Pid := 0
	if !Saved.Window || !DllCall("User32\IsWindow", "Ptr", Saved.Window, "Int")
		return
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Saved.Window, "UInt*", &Pid)
	if Pid != Saved.Pid
		return
	WinActivate("ahk_id " . Saved.Window)
	if Saved.Control && DllCall("User32\IsChild", "Ptr", Saved.Window, "Ptr", Saved.Control, "Int")
		ControlFocus(Saved.Control)
}

_NECP_Run(Delayed) {
	global _DriverDir, _TEXT_NATIVE_OWNER
	static Debt := 0, Serial := 0
	AssertFalse(IsObject(Debt), "SETUP: an earlier exact editor receiver still owns retirement debt")
	AssertFalse(IsObject(_TEXT_NATIVE_OWNER), "SETUP: the native output queue must be idle")
	SavedCritical := Critical("Off"), SavedSuspend := A_IsSuspended
	SavedFocus := _NECP_SavedFocus()
	State := {Calls: 0, Code: -1, Output: "", ErrorText: "", Process: 0, Pid: 0,
		WorkerStarted: false, WorkerClosed: false, Exports: 0, Token: 0x454350000 + ++Serial}
	Task := 0, Events := [], Primary := 0, Retired := false, NativeRetired := false, Passed := false
	Root := A_Temp . "\ergopti_native_editor_peer_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	BaseName := "Local\ErgoptiEditorPeer_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	try {
		Suspend(false)
		AssertTrue(FSCreateDirectoryExclusiveStrict(Root), "SETUP: own the private receiver directory")
		State.Exports := _NECP_Exports()
		for Suffix in ["entered", "release", "stop"]
			Events.Push(_NECP_Event(BaseName . "_" . Suffix))
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", _DriverDir . "\tests\fixtures\native_editor_cross_process_receiver.ahk",
				Root, Delayed ? "delay" : "positive", BaseName, String(ProcessExist())],
			_NECP_Done.Bind(State), , _NECP_Adopt.Bind(State))
		AssertTrue(Task.start(), "SETUP: start the exact owned receiver process")
		_NECP_WaitFile(State, Root . "\ready", "SETUP")
		Ready := StrSplit(FSReadUtf8Exact(Root . "\ready"), "|")
		AssertEqual(3, Ready.Length, "SETUP: complete receiver identity receipt")
		AssertEqual(State.Pid, Integer(Ready[1]), "SETUP: native launch and receiver PID agree")
		AssertTrue(State.Pid != ProcessExist(), "SETUP: the production ABI requires another process")
		Window := Integer(Ready[2]), Control := Integer(Ready[3]), Pid := 0
		DllCall("User32\GetWindowThreadProcessId", "Ptr", Window, "UInt*", &Pid)
		AssertEqual(State.Pid, Pid, "SETUP: exact top-level window process")
		DllCall("User32\GetWindowThreadProcessId", "Ptr", Control, "UInt*", &Pid)
		AssertEqual(State.Pid, Pid, "SETUP: exact edit control process")
		AssertTrue(DllCall("User32\IsChild", "Ptr", Window, "Ptr", Control, "Int"), "SETUP: exact native child relationship")
		AssertEqual("Edit", WinGetClass("ahk_id " . Control), "SETUP: a genuine native Edit class")
		AssertEqual("left " . Chr(0x1F600) . " tail", ControlGetText(Control), "SETUP: actual receiver seed")
		WinActivate("ahk_id " . Window)
		AssertTrue(WinWaitActive("ahk_id " . Window, , 3), "SETUP: the exact receiver becomes foreground")
		ControlFocus(Control)
		Focus := _TextSenderNativeFocus()
		AssertEqual(Window, Focus["hwnd"], "SETUP: production foreground witness")
		AssertEqual(Control, Focus["control"], "SETUP: production GetGUIThreadInfo focus witness")
		AssertEqual(State.Pid, Focus["pid"], "SETUP: production focused PID witness")
		Selection := Buffer(8, 0)
		MessageResult := 0
		AssertTrue(DllCall("User32\SendMessageTimeoutW", "Ptr", Control, "UInt", 0xB0,
			"Ptr", Selection, "Ptr", Selection.Ptr + 4, "UInt", 0x23, "UInt", 1000,
			"UPtr*", &MessageResult, "Ptr"), "SETUP: actual selection receipt")
		AssertEqual(7, NumGet(Selection, 0, "UInt"), "SETUP: exact collapsed start")
		AssertEqual(7, NumGet(Selection, 4, "UInt"), "SETUP: exact collapsed end")
		Deleted := Chr(0x1F600), Inserted := Chr(0xE9) . Chr(0x1F642)
		AssertEqual(0, DllCall(State.Exports["Begin"], "UInt64", State.Token,
			"UInt64", Window, "UInt64", Control, "UInt", State.Pid,
			"Ptr", StrPtr(Deleted), "Ptr", StrPtr(Inserted), "Int"), "BUSINESS: actual production Begin")
		State.WorkerStarted := true
		Receipt := _NECP_Phase(State.Exports, State.Token, 2)
		AssertEqual(2, Receipt.Phase, "BUSINESS: real document and selection prepare successfully")
		AssertEqual(5, DllCall(State.Exports["Close"], "UInt64", State.Token, "Int"),
			"BUSINESS: a prepared live worker cannot release its strings")
		Focus := _TextSenderNativeFocus()
		AssertEqual(Window, Focus["hwnd"], "SETUP: exact foreground persists until decision")
		AssertEqual(Control, Focus["control"], "SETUP: exact control persists until decision")
		AssertEqual(0, DllCall(State.Exports["Decide"], "UInt64", State.Token, "UInt", 1, "Int"),
			"BUSINESS: actual production decision")
		Receipt := _NECP_Phase(State.Exports, State.Token, 4)
		AssertEqual(Delayed ? 6 : 4, Receipt.Phase, "BUSINESS: timeout is indeterminate; ordinary output succeeds")
		AssertEqual(Delayed ? 1460 : 0, Receipt.NativeError, "BUSINESS: actual Win32 timeout receipt")
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Events[1], "UInt", 0, "UInt"),
			"BUSINESS: the real receiver entered EM_REPLACESEL")
		AssertTrue(_NECP_CloseWorker(State), "BUSINESS: actual worker exit precedes freeing its strings")
		AssertEqual(8, DllCall(State.Exports["Close"], "UInt64", State.Token, "Int"),
			"BUSINESS: exact retired token cannot close twice")
		if Delayed {
			AssertEqual(258, DllCall("Kernel32\WaitForSingleObject", "Ptr", State.Process, "UInt", 0, "UInt"),
				"BUSINESS: delayed receiver outlives the exact sender worker")
			AssertFalse(FileExist(Root . "\settled"), "BUSINESS: receiver has not consumed replacement before release")
			AssertTrue(DllCall("Kernel32\SetEvent", "Ptr", Events[2], "Int"), "BUSINESS: release the exact blocked receiver")
		}
		_NECP_WaitFile(State, Root . "\settled", "BUSINESS")
		AssertEqual("1|8|8", FSReadUtf8Exact(Root . "\settled"), "BUSINESS: one replacement and exact DWORD caret receipt")
		AssertEqual("left " . Inserted . " tail", FSReadUtf8Exact(Root . "\text"), "BUSINESS: independent receiver text is complete")
		Passed := true
	} catch Any as Err {
		Primary := Err
	} finally {
		; Never retire the receiver while its exact native worker may address it.
		try {
			if Events.Length >= 2
				AssertTrue(DllCall("Kernel32\SetEvent", "Ptr", Events[2], "Int"), "RETIREMENT: unblock the owned receiver")
			NativeRetired := _NECP_CloseWorker(State)
			if NativeRetired && IsObject(Task) {
				if Events.Length >= 3
					AssertTrue(DllCall("Kernel32\SetEvent", "Ptr", Events[3], "Int"), "RETIREMENT: request owned receiver stop")
				Started := A_TickCount
				while State.Calls == 0 && TickElapsed(Started) < 5000 {
					_SR_TreePoll()
					Sleep(10)
				}
				if State.Calls == 1
					Retired := Task.terminate() == 1
			} else if !IsObject(Task)
				Retired := NativeRetired
			if Retired && State.Process
				AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", State.Process, "UInt", 0, "UInt"),
					"RETIREMENT: the retained exact receiver process must be signaled")
		} catch Any as Err {
			Retired := false
			if !IsObject(Primary)
				Primary := Err
		}
		if Retired {
			try {
				for Index, Handle in Events {
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "RETIREMENT: close exact event")
					Events[Index] := 0
				}
				if State.Process {
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", State.Process, "Int"), "RETIREMENT: close exact process reference")
					State.Process := 0
				}
			} catch Any as Err {
				Retired := false
				if !IsObject(Primary)
					Primary := Err
			}
		}
		if !Retired
			Debt := {Task: Task, State: State, Events: Events, Root: Root}
		try _NECP_RestoreFocus(SavedFocus)
		catch Any as Err {
			if !IsObject(Primary)
				Primary := Err
		} finally {
			Suspend(SavedSuspend)
			Critical(SavedCritical)
		}
	}
	_TestPrint("# native-editor-cross-process delayed=" . Delayed . " passed=" . Passed
		. " native_closed=" . State.WorkerClosed . " receiver_retired=" . Retired . " calls=" . State.Calls
		. " code=" . State.Code . " errors=" . State.ErrorText)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "RETIREMENT: exact native worker and receiver resources must retire")
	AssertEqual(1, State.Calls, "BUSINESS: exact child completion occurs once")
	AssertEqual(0, State.Code, "BUSINESS: actual receiver exits successfully: " . State.Output . State.ErrorText)
	AssertEqual("PASS native editor receiver", State.Output, "BUSINESS: exact receiver completion witness")
	AssertEqual("", State.ErrorText, "BUSINESS: no hidden child errors")
	DirDelete(Root, true)
}

Test("Native editor: shipped DLL receives actual cross-process supplementary replacement (native-editor-cross-process)",
	_NECP_Run.Bind(false))
Test("Native editor: shipped DLL retires sender before delayed receiver consumes text (native-editor-cross-process)",
	_NECP_Run.Bind(true))
