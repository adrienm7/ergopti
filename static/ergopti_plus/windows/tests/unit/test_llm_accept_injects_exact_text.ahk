; tests/unit/test_llm_accept_injects_exact_text.ahk

; ==============================================================================
; MODULE: An accepted prediction is typed once, exactly, at SendLevel 0
; DESCRIPTION:
; Regression for llm-accept-injects-exact-text. The physical Tab accepts a
; shown prediction from its SC00F hotkey (platform/remap/tab.ahk), which
; ErgoptiPlus.ahk includes under #InputLevel 2, so the accepting thread runs at
; SendLevel 2. TextSend's atomic outputs called their send primitive directly:
; the prediction left at the caller's SendLevel 2 instead of
; TEXT_SENDER_SEND_LEVEL, as input every hook below level 2 takes for typing
; (the native navigation owner's routes at level 1, the driver's own I1
; InputHooks whenever SendInput falls back to SendEvent, any other AutoHotkey
; hook). The validation chord inserts from a timer thread, at level 0, so only
; the Tab path sent that way.
;
; The tests drive the real acceptance: the dispatch both acceptance primitives
; end in (_LLM_Accept_ClaimAndDispatch, run as the Tab hotkey thread at level
; 2) and the validation-chord primitive (LLM_Tooltip_TryAcceptSlot), through
; LLM_Bridge_OnAccept and TextSend, into a fake SendInput port that records
; every payload with the SendLevel it left at. The prediction is multi-word and
; accented: it must leave as one Text-mode batch carrying it exactly, which no
; keyboard layout can remap.
; ==============================================================================

#Requires AutoHotkey v2.0

; What the user typed, then the prediction accepted after it: every accented
; letter and typographic mark of the report (é, è, à, ç, œ, …, ’) in several
; words.
global LAIET_TYPED := "napoléon est le plus "
global LAIET_PREDICTION := "grand empereur français : œuvre à l’été… déjà très célèbre"
; The window and control the prediction was rendered for, which the fake focus
; probe reports as live.
global LAIET_HWND := 100
global LAIET_CONTROL := 1001

; Runs Body(Sent, Record) with the prediction on screen, a fake SendInput port
; recording { Keys, Level } and the live focus on the rendered control, then
; restores every piece of state the acceptance commits.
_LAIET_Run(Body) {
	global _AHK_SendInput, _LLM_Engine, _LLM_AcceptInProgress, _LLM_Bridge_Buffer
	global _LLM_Bridge_ReadLiveFocus, _Stub_LlmTooltipCalls
	global _Stub_LlmTooltipVisible, _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
	global HSE_Buffer, HSE_StartIsWordBoundary
	global _PrefixBuffer, _PrefixFocusedControlToken
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	global LAIET_TYPED, LAIET_PREDICTION, LAIET_HWND, LAIET_CONTROL
	Saved := {
		Send: _AHK_SendInput, Engine: _LLM_Engine, InProgress: _LLM_AcceptInProgress,
		Buffer: _LLM_Bridge_Buffer, Focus: _LLM_Bridge_ReadLiveFocus,
		Calls: _Stub_LlmTooltipCalls, Visible: _Stub_LlmTooltipVisible,
		Text: _Stub_LlmTooltipText, Record: _Stub_LlmPresentedRecord,
		Hse: HSE_Buffer, HseBoundary: HSE_StartIsWordBoundary,
		Prefix: _PrefixBuffer, PrefixControl: _PrefixFocusedControlToken,
		PrefixGeneration: _PrefixContentGeneration,
		ContextGeneration: _PrefixInputContextGeneration,
		LscRing: _LSC_RING.Clone(), LscCursor: _LSC_CURSOR, LscLen: _LSC_LEN,
		Level: A_SendLevel
	}
	Sent := []
	try {
		_AHK_SendInput := (Keys) => Sent.Push({ Keys: Keys, Level: A_SendLevel })
		_LLM_Bridge_ReadLiveFocus := () => Map("hwnd", LAIET_HWND, "control", LAIET_CONTROL)
		_LLM_Engine := _LLM_Engine.Clone()
		_LLM_Engine["request_id"] := 41
		_LLM_AcceptInProgress := false
		_LLM_Bridge_Buffer := LAIET_TYPED
		_Stub_LlmTooltipCalls := []
		Source := Map("hwnd", LAIET_HWND, "control", LAIET_CONTROL, "request_id", 41)
		_Stub_LlmPresentedRecord := {
			Kind: "prediction", Slots: [LAIET_PREDICTION], ActiveIdx: 1,
			Lifecycle: {
				OfferId: 41, AcceptSource: Source, AppName: "source.exe",
				Slots: [LAIET_PREDICTION], Suggested: true, Outcome: ""
			},
			IsFinal: true, Generation: 1, ShownAt: A_TickCount
		}
		_Stub_LlmTooltipVisible := true
		_Stub_LlmTooltipText := LAIET_PREDICTION
		Body(Sent, _Stub_LlmPresentedRecord)
	} finally {
		; The accepted tooltip hides on the next scheduler turn: let that run
		; while this record is still the presented one, then drop the claim
		; release this acceptance deferred.
		Sleep(20)
		try SetTimer(_LLM_Accept_ReleaseClaim, 0)
		SendLevel(Saved.Level)
		_AHK_SendInput := Saved.Send
		_LLM_Bridge_ReadLiveFocus := Saved.Focus
		_LLM_Engine := Saved.Engine
		_LLM_AcceptInProgress := Saved.InProgress
		_LLM_Bridge_Buffer := Saved.Buffer
		_Stub_LlmTooltipCalls := Saved.Calls
		_Stub_LlmTooltipVisible := Saved.Visible
		_Stub_LlmTooltipText := Saved.Text
		_Stub_LlmPresentedRecord := Saved.Record
		HSE_Buffer := Saved.Hse
		HSE_StartIsWordBoundary := Saved.HseBoundary
		_PrefixBuffer := Saved.Prefix
		_PrefixFocusedControlToken := Saved.PrefixControl
		_PrefixContentGeneration := Saved.PrefixGeneration
		_PrefixInputContextGeneration := Saved.ContextGeneration
		_LSC_RING := Saved.LscRing
		_LSC_CURSOR := Saved.LscCursor
		_LSC_LEN := Saved.LscLen
	}
}

; The one emission an accepted prediction may produce.
_LAIET_AssertTypedOnce(Sent) {
	global LAIET_PREDICTION, TEXT_SENDER_SEND_LEVEL
	AssertEqual(1, Sent.Length,
		"the whole prediction must leave in one SendInput batch, never one call per character")
	AssertEqual("{Text}" . LAIET_PREDICTION, Sent[1].Keys,
		"the payload must be the exact accented prediction in Text mode, which no keyboard layout remaps")
	AssertEqual(TEXT_SENDER_SEND_LEVEL, Sent[1].Level,
		"the prediction must leave at TextSender's SendLevel, never the accepting hotkey's #InputLevel 2 (llm-accept-injects-exact-text)")
}

_LAIET_TabTypesThePredictionOnceAtLevelZero() {
	_LAIET_Run(_Body)
	_Body(Sent, Record) {
		global LAIET_TYPED, LAIET_PREDICTION, _LLM_Bridge_Buffer
		; The SC00F hotkey thread runs at its #InputLevel, and the Tab primitive
		; hands its policy-approved snapshot to this dispatch.
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()),
			"the shown prediction must be claimed and dispatched")
		AssertEqual(2, A_SendLevel, "the accepting hotkey thread keeps its own SendLevel")
		_LAIET_AssertTypedOnce(Sent)
		AssertEqual(LAIET_TYPED . LAIET_PREDICTION, _LLM_Bridge_Buffer,
			"the bridge buffer mirrors the prediction exactly once")
		AssertEqual("accepted", Record.Lifecycle.Outcome,
			"the presented offer is retired as accepted")
	}
}
Test("LLM accept: Tab types the exact accented prediction once, at SendLevel 0 (llm-accept-injects-exact-text)",
	_LAIET_TabTypesThePredictionOnceAtLevelZero)

_LAIET_ValidationChordTypesThePredictionOnceAtLevelZero() {
	_LAIET_Run(_Body)
	_Body(Sent, Record) {
		global LAIET_TYPED, LAIET_PREDICTION, LAIET_HWND, LAIET_CONTROL
		global _LLM_Bridge_Buffer
		; The chord inserts from a timer thread once its modifiers are released.
		SendLevel(0)
		Snapshot := Map("known", true, "tab_down", false, "ctrl_down", false,
			"alt_down", false, "shift_down", false, "win_down", false,
			"current_hwnd", LAIET_HWND, "current_control", LAIET_CONTROL)
		AssertTrue(LLM_Tooltip_TryAcceptSlot(Record, Record, 1, Snapshot),
			"the validation chord must insert the slot it chose")
		_LAIET_AssertTypedOnce(Sent)
		AssertEqual(LAIET_TYPED . LAIET_PREDICTION, _LLM_Bridge_Buffer,
			"the bridge buffer mirrors the prediction exactly once")
	}
}
Test("LLM accept: the validation chord types the exact accented prediction once (llm-accept-injects-exact-text)",
	_LAIET_ValidationChordTypesThePredictionOnceAtLevelZero)

; Every TextSender output path, not only the accepted prediction's: the plain
; direct SendText and the atomic runner, which carries both the direct text and
; the clipboard's Ctrl+V, leave at TEXT_SENDER_SEND_LEVEL from a level-2 thread
; and give that thread its level back, even when the send throws.
_LAIET_EveryTextSenderPathLeavesAtLevelZero() {
	global _AHK_SendText, TEXT_SENDER_SEND_LEVEL, LAIET_PREDICTION
	SavedSendText := _AHK_SendText
	PreviousLevel := A_SendLevel
	Levels := []
	try {
		SendLevel(2)
		_AHK_SendText := (Text) => Levels.Push(A_SendLevel)
		Results := []
		TextSend(LAIET_PREDICTION, Map("mode", "direct"),
			(Ok, ErrorMessage := "") => Results.Push(Ok))
		Atomic := _TextSenderRunAtomicOutput(() => Levels.Push(A_SendLevel), Map(),
			"level probe")
		AssertEqual(2, Levels.Length, "each path must emit exactly once")
		AssertEqual(TEXT_SENDER_SEND_LEVEL, Levels[1],
			"the plain direct SendText must leave at TextSender's SendLevel")
		AssertEqual(TEXT_SENDER_SEND_LEVEL, Levels[2],
			"the atomic runner (direct text and clipboard paste) must leave at TextSender's SendLevel")
		AssertTrue(Results.Length == 1 && Results[1], "the direct send reports its output")
		AssertTrue(Atomic.Ok, "the atomic runner reports its output")
		AssertEqual(2, A_SendLevel, "the caller's SendLevel must be restored")
		AssertThrows(() => _TextSenderAtSendLevel(() => _LAIET_ThrowSendFailure()),
			"a failing emission must propagate to the path that reports it")
		AssertEqual(2, A_SendLevel, "a failing emission must restore the caller's SendLevel too")
	} finally {
		_AHK_SendText := SavedSendText
		SendLevel(PreviousLevel)
	}
}
Test("LLM accept: every TextSender path leaves at SendLevel 0 and restores the caller's (llm-accept-injects-exact-text)",
	_LAIET_EveryTextSenderPathLeavesAtLevelZero)

_LAIET_ThrowSendFailure() {
	throw Error("simulated SendInput failure")
}

; Notepad uses the native editor owner rather than a keyboard paste batch. The
; controlled port advances its real asynchronous state machine; admission,
; journal preparation, atomic settlement and offer completion remain production.
_LAIET_NativeFixture() {
	global LAIET_HWND, LAIET_CONTROL
	State := { Trace: [], Phase: 1, Scheduled: 0, ScheduleCalls: 0, Owner: 0,
		Begins: 0, Decisions: 0, Closed: 0 }
	State.Port := Map(
		"focus", () => Map("hwnd", LAIET_HWND, "control", LAIET_CONTROL, "pid", 77),
		"begin", (Owner) => (State.Owner := Owner, State.Begins += 1,
			State.Trace.Push("begin"), 0),
		"poll", (Token) => Map("phase", State.Phase, "os_error", 0),
		"decide", (Token, Commit) => (State.Decisions += 1,
			State.Trace.Push("decide:" . Commit), 0),
		"close", (Token) => (State.Closed += 1, State.Trace.Push("close"), 0),
		"schedule", (Fn) => (State.ScheduleCalls += 1, State.Scheduled := Fn)
	)
	return State
}

_LAIET_WithNativePort(Body) {
	global _TextSenderNativeTestPort, _TEXT_NATIVE_OWNER, _TEXT_NATIVE_SERIAL
	global _TEXT_CLIPBOARD_QUEUE, _Stub_OutputHostExe, _Stub_OutputHostTitle
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE, _OUTPUT_HOST_METADATA_PROBE
	global _OUTPUT_HOST_TITLE_PROBE, _OUTPUT_HOST_RESOLVE_SERIAL
	AssertFalse(_TEXT_NATIVE_OWNER, "the native fixture cannot adopt another output owner")
	Saved := { Port: _TextSenderNativeTestPort, Owner: _TEXT_NATIVE_OWNER,
		Serial: _TEXT_NATIVE_SERIAL, Queue: _TEXT_CLIPBOARD_QUEUE,
		QueueLength: _TEXT_CLIPBOARD_QUEUE.Length, App: KLHook.prev_app,
		Title: KLHook.prev_title, Exe: _Stub_OutputHostExe, StubTitle: _Stub_OutputHostTitle,
		Cache: _OUTPUT_HOST_CACHE, Identity: _OUTPUT_HOST_IDENTITY_PROBE,
		Metadata: _OUTPUT_HOST_METADATA_PROBE, TitleProbe: _OUTPUT_HOST_TITLE_PROBE,
		HostSerial: _OUTPUT_HOST_RESOLVE_SERIAL }
	State := _LAIET_NativeFixture()
	try {
		_TextSenderNativeTestPort := State.Port
		SimulateNotepadActive()
		_LAIET_Run(Body.Bind(State))
		AssertEqual(Saved.QueueLength, _TEXT_CLIPBOARD_QUEUE.Length,
			"native acceptance must not publish a clipboard request")
		AssertTrue(_TEXT_CLIPBOARD_QUEUE == Saved.Queue,
			"the native fixture must preserve the existing clipboard FIFO")
	} finally {
		_TextSenderNativeTestPort := Saved.Port
		_TEXT_NATIVE_OWNER := Saved.Owner
		_TEXT_NATIVE_SERIAL := Saved.Serial
		KLHook.prev_app := Saved.App
		KLHook.prev_title := Saved.Title
		_Stub_OutputHostExe := Saved.Exe
		_Stub_OutputHostTitle := Saved.StubTitle
		_OUTPUT_HOST_CACHE := Saved.Cache
		_OUTPUT_HOST_IDENTITY_PROBE := Saved.Identity
		_OUTPUT_HOST_METADATA_PROBE := Saved.Metadata
		_OUTPUT_HOST_TITLE_PROBE := Saved.TitleProbe
		_OUTPUT_HOST_RESOLVE_SERIAL := Saved.HostSerial
	}
}

_LAIET_CompleteNative(State, Sent, Record, Text, Count, Deleted, ExpectedBuffer) {
	global _TEXT_NATIVE_OWNER, _LLM_Bridge_Buffer
	Owner := _TEXT_NATIVE_OWNER
	AssertTrue(IsObject(Owner), "the real TextSender must own the deferred replacement")
	AssertEqual(0, Sent.Length, "native replacement must not emit keyboard text or paste")
	AssertEqual(0, State.Begins, "dispatch must return before starting the native worker")
	AssertEqual(Text, Owner.Text, "the exact accepted prediction belongs to the native request")
	AssertEqual(Count, Owner.Opts.Get("erase_before", 0), "the slot's codepoint count is retained")
	AssertEqual(Deleted, Owner.Opts.Get("deleted_text", ""), "the native request owns the exact UTF-16 tail")
	AssertTrue(_TextSenderHasAtomicHooks(Owner.Opts), "real admission and journal/commit hooks must remain attached")
	Before := _LLM_Bridge_Buffer
	State.Scheduled.Call()
	AssertEqual(1, State.Begins, "the first scheduler step starts exactly one native request")
	AssertTrue(State.Owner == Owner, "the native port receives the actual queued owner")
	AssertTrue(Owner.Prepared is Map, "the actual journal preparation returns its token")
	AssertEqual(Before, _LLM_Bridge_Buffer, "preparation cannot publish the mirror")
	AssertEqual("claimed", Record.Lifecycle.Outcome, "preparation cannot retire the offer")
	State.Phase := 2
	State.Scheduled.Call()
	AssertEqual("begin|decide:1", _TSCS_Join(State.Trace), "ready admission authorizes one mutation")
	AssertEqual(Before, _LLM_Bridge_Buffer, "mutation authorization is not verified output")
	AssertEqual("claimed", Record.Lifecycle.Outcome, "ready is not completion")
	State.Phase := 4
	State.Scheduled.Call()
	AssertEqual("begin|decide:1|close", _TSCS_Join(State.Trace), "verified output is retired before settlement")
	AssertEqual(1, State.Closed, "the native request closes exactly once")
	AssertEqual(0, Sent.Length, "settlement must not fall back to a keyboard batch")
	AssertEqual(ExpectedBuffer, _LLM_Bridge_Buffer, "the canonical mirror applies deletion and replacement once")
	AssertEqual("accepted", Record.Lifecycle.Outcome, "only verified retired output accepts the offer")
	AssertFalse(_TEXT_NATIVE_OWNER, "the verified native request releases its AHK owner")
	_TextSenderPollNative(Owner)
	AssertEqual(1, State.Begins, "duplicate polling must not execute the editor again")
	AssertEqual(1, State.Decisions, "duplicate polling must not authorize another mutation")
	AssertEqual(1, State.Closed, "duplicate polling must not retire the worker again")
	AssertEqual(ExpectedBuffer, _LLM_Bridge_Buffer, "duplicate completion cannot apply the mirror twice")
	AssertEqual(2, A_SendLevel, "native completion preserves the accepting thread's SendLevel")
}

_LAIET_NotepadReceivesThePredictionByNativeOwner() {
	_LAIET_WithNativePort(_Body)
	_Body(State, Sent, Record) {
		global LAIET_TYPED, LAIET_PREDICTION, _LLM_Bridge_Buffer
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()),
			"the shown prediction must be claimed and dispatched")
		AssertEqual(LAIET_TYPED, _LLM_Bridge_Buffer, "queued insertion cannot update the mirror")
		_LAIET_CompleteNative(State, Sent, Record, LAIET_PREDICTION, 0, "",
			LAIET_TYPED . LAIET_PREDICTION)
	}
}
Test("LLM accept: Notepad receives the exact prediction through its native owner (llm-accept-notepad-paste)",
	_LAIET_NotepadReceivesThePredictionByNativeOwner)

_LAIET_AutoModeUsesNativeInNotepadOnly() {
	_LAIET_WithNativePort(_Body)
	_Body(State, Sent, Record) {
		global _AHK_SendText, _TEXT_NATIVE_OWNER, _TEXT_CLIPBOARD_QUEUE
		SavedSend := _AHK_SendText
		Typed := []
		QueueLength := _TEXT_CLIPBOARD_QUEUE.Length
		try {
			_AHK_SendText := (Text) => Typed.Push(Text)
			SimulateRegularApp()
			TextSend("court", Map("mode", "auto"), 0)
			AssertEqual(1, Typed.Length, "a short text is typed in an ordinary application")
			AssertFalse(_TEXT_NATIVE_OWNER, "an ordinary short insertion starts no native job")
			SimulateNotepadActive()
			TextSend("court", Map("mode", "auto"), 0)
			AssertEqual(1, Typed.Length, "Notepad must not receive keyboard text")
			AssertEqual("court", _TEXT_NATIVE_OWNER.Text, "auto mode queues the exact native literal")
			State.Scheduled.Call()
			State.Phase := 2
			State.Scheduled.Call()
			State.Phase := 4
			State.Scheduled.Call()
			AssertEqual("begin|decide:1|close", _TSCS_Join(State.Trace), "auto mode runs the real native owner once")
			AssertFalse(_TEXT_NATIVE_OWNER, "auto mode retires its completed native request")
			AssertEqual(QueueLength, _TEXT_CLIPBOARD_QUEUE.Length, "neither short insertion uses the clipboard")
			AssertTrue(OutputHostTakesTextByPaste(OutputHostResolve()), "Notepad retains its host strategy classification")
			SimulateRegularApp()
			AssertFalse(OutputHostTakesTextByPaste(OutputHostResolve()), "ordinary applications retain direct output")
			AssertFalse(OutputHostTakesTextByPaste(_OutputHostInvalidReceipt("identity_unavailable")),
				"an unknown host is not classified as Notepad")
		} finally _AHK_SendText := SavedSend
	}
}
Test("TextSender: auto mode uses native Notepad output and types elsewhere (llm-accept-notepad-paste)",
	_LAIET_AutoModeUsesNativeInNotepadOnly)

_LAIET_ConfigureRewrite(Record, Text, DeletedText, Span, Count) {
	Slot := { Text: Text, Deletes: Count, DeletedText: DeletedText, RewriteSpan: Span }
	Record.Slots := ["unused first slot", "unused second slot", Slot]
	Record.ActiveIdx := 3
	Record.Lifecycle.Slots := Record.Slots.Clone()
}

_LAIET_NotepadIncidentCorrectionByNativeOwner() {
	_LAIET_WithNativePort(_Body)
	_Body(State, Sent, Record) {
		global _LLM_Bridge_Buffer
		Typed := "napéoléon is the"
		Correction := "Napoleon is the greatest emperor in French history"
		AssertEqual(16, StrLen(Typed), "the reported deletion has sixteen UTF-16 units and codepoints")
		AssertEqual(50, StrLen(Correction), "the reported third slot contains fifty characters")
		_LLM_Bridge_Buffer := Typed
		_LAIET_ConfigureRewrite(Record, Correction, Typed, Typed, 16)
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()), "the third rewrite slot is dispatched")
		_LAIET_CompleteNative(State, Sent, Record, Correction, 16, Typed, Correction)
	}
}
Test("LLM accept: the Notepad incident's third correction owns the exact native tail (llm-rewrite-paste-recording)",
	_LAIET_NotepadIncidentCorrectionByNativeOwner)

_LAIET_NotepadScalarErasureByNativeOwner() {
	_LAIET_WithNativePort(_Body)
	_Body(State, Sent, Record) {
		global _LLM_Bridge_Buffer
		Deleted := "i" . Chr(0x1F600)
		Span := "Je sui" . Chr(0x1F600)
		Correction := "is déjà allé."
		AssertEqual(3, StrLen(Deleted), "the deleted suffix occupies three UTF-16 units")
		_LLM_Bridge_Buffer := "Avant. " . Span
		_LAIET_ConfigureRewrite(Record, Correction, Deleted, Span, 2)
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()), "the supplementary-character rewrite is dispatched")
		_LAIET_CompleteNative(State, Sent, Record, Correction, 2, Deleted, "Avant. Je suis déjà allé.")
	}
}
Test("LLM accept: native Notepad rewrite preserves codepoints and the exact UTF-16 tail (llm-rewrite-paste-recording)",
	_LAIET_NotepadScalarErasureByNativeOwner)

_LAIET_NotepadStaleRewriteNeverStartsNative() {
	_LAIET_WithNativePort(_Body)
	_Body(State, Sent, Record) {
		global _LLM_Bridge_Buffer, _TEXT_NATIVE_OWNER
		Typed := "napéoléon is the"
		_LLM_Bridge_Buffer := Typed . " changed"
		_LAIET_ConfigureRewrite(Record,
			"Napoleon is the greatest emperor in French history", Typed, Typed, 16)
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()), "dispatch is distinct from successful output")
		AssertEqual(0, Sent.Length, "a stale rewrite must emit no keyboard batch")
		AssertFalse(_TEXT_NATIVE_OWNER, "a changed rewrite span cannot acquire a native output owner")
		AssertEqual(0, State.ScheduleCalls, "a refused correction cannot schedule native work")
		AssertEqual(0, State.Begins, "a refused correction cannot start an editor worker")
		AssertEqual(Typed . " changed", _LLM_Bridge_Buffer, "refusal preserves the changed text")
		AssertEqual("dismissed", Record.Lifecycle.Outcome, "refusal cannot retire the offer as accepted")
	}
}
Test("LLM accept: stale Notepad correction refuses before native acquisition (llm-rewrite-paste-recording)",
	_LAIET_NotepadStaleRewriteNeverStartsNative)
_LAIET_OptionsKeepExactDeletedText() {
	Deleted := "Ab" . Chr(0xA0) . Chr(0x1F600)
	Transaction := {Deletes: 4, DeletedText: Deleted, Admission: () => true}
	Opts := _LLM_Bridge_InjectionOptions(Transaction)
	AssertTrue(Opts.Has("deleted_text"), "the native sender requires exact deletion text")
	AssertEqual(Deleted, Opts["deleted_text"], "case, NBSP and surrogate units are copied unchanged")
	AssertEqual(4, Opts["erase_before"], "the legacy codepoint count remains independently unchanged")
	AssertEqual(5, StrLen(Opts["deleted_text"]), "the native deletion text uses its actual UTF-16 length")
}
Test("LLM accept: native options preserve the exact deleted tail (notepad-pending)",
	_LAIET_OptionsKeepExactDeletedText)
