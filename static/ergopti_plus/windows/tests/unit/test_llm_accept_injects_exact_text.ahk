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

; Regression for llm-accept-notepad-paste. Windows 11's Notepad loses the
; characters of a text typed in one burst and types the last one in their
; place: « général de l’histoire militaire » accepted there came out as its
; final « e » 32 times (2026-10-01). The hotstring engine already pastes its
; replacement in that application; the accepted prediction typed it as text.
; The clipboard worker is stopped before it runs, so the test never touches
; the real clipboard: it takes the queued request and sends the paste the
; worker sends once the clipboard holds the text.
_LAIET_NotepadReceivesThePredictionByPaste() {
	global _TEXT_CLIPBOARD_QUEUE
	SavedQueue := _TEXT_CLIPBOARD_QUEUE
	SimulateNotepadActive()
	try {
		_TEXT_CLIPBOARD_QUEUE := []
		_LAIET_Run(_Body)
	} finally {
		SetTimer(_TextSenderStartClipboard, 0)
		_TEXT_CLIPBOARD_QUEUE := SavedQueue
		SimulateRegularApp()
	}
	_Body(Sent, Record) {
		global LAIET_TYPED, LAIET_PREDICTION, _LLM_Bridge_Buffer
		global _TEXT_CLIPBOARD_QUEUE, _AHK_SendInput, TEXT_SENDER_SEND_LEVEL
		SendLevel(2)
		AssertTrue(_LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot()),
			"the shown prediction must be claimed and dispatched")
		SetTimer(_TextSenderStartClipboard, 0)
		AssertEqual(0, Sent.Length,
			"in Notepad the prediction must not be typed as text, which Notepad garbles (llm-accept-notepad-paste)")
		AssertEqual(1, _TEXT_CLIPBOARD_QUEUE.Length,
			"in Notepad the prediction must be queued for exactly one paste")
		Request := _TEXT_CLIPBOARD_QUEUE.RemoveAt(1)
		AssertEqual(LAIET_PREDICTION, Request.Text,
			"the pasted text must be the exact accented prediction")
		Result := _TextSenderRunAtomicOutput(
			_AHK_SendInput.Bind(_TextSenderErasePrefix(Request.Opts) . "^v"),
			Request.Opts, "clipboard paste")
		Request.Callback.Call(Result.Ok, Result.ErrorMessage)
		AssertEqual(1, Sent.Length, "the paste is one keystroke batch")
		AssertEqual("^v", Sent[1].Keys, "an insertion erases nothing before its paste")
		AssertEqual(TEXT_SENDER_SEND_LEVEL, Sent[1].Level,
			"the paste must leave at TextSender's SendLevel")
		AssertEqual(LAIET_TYPED . LAIET_PREDICTION, _LLM_Bridge_Buffer,
			"the bridge buffer mirrors the pasted prediction exactly once")
		AssertEqual("accepted", Record.Lifecycle.Outcome,
			"the presented offer is retired as accepted")
	}
}
Test("LLM accept: Notepad receives the prediction by paste, never as typed text (llm-accept-notepad-paste)",
	_LAIET_NotepadReceivesThePredictionByPaste)

; The choice belongs to TextSend's "auto" mode, so every caller that leaves the
; strategy to the adapter gets it: a short text is typed everywhere but in
; Notepad, where it is queued for a paste.
_LAIET_AutoModePastesInNotepadOnly() {
	global _TEXT_CLIPBOARD_QUEUE, _AHK_SendText
	SavedQueue := _TEXT_CLIPBOARD_QUEUE
	SavedSendText := _AHK_SendText
	Typed := []
	try {
		_TEXT_CLIPBOARD_QUEUE := []
		_AHK_SendText := (Text) => Typed.Push(Text)
		SimulateRegularApp()
		TextSend("court", Map("mode", "auto"), 0)
		SetTimer(_TextSenderStartClipboard, 0)
		AssertEqual(1, Typed.Length, "a short text is typed in an ordinary application")
		AssertEqual(0, _TEXT_CLIPBOARD_QUEUE.Length,
			"a short text is not pasted in an ordinary application")
		SimulateNotepadActive()
		TextSend("court", Map("mode", "auto"), 0)
		SetTimer(_TextSenderStartClipboard, 0)
		AssertEqual(1, Typed.Length,
			"in Notepad a text left to the adapter must not be typed (llm-accept-notepad-paste)")
		AssertEqual(1, _TEXT_CLIPBOARD_QUEUE.Length,
			"in Notepad a text left to the adapter is queued for a paste")
		AssertTrue(OutputHostTakesTextByPaste(OutputHostResolve()),
			"Notepad is the host that takes text by paste")
		SimulateRegularApp()
		AssertFalse(OutputHostTakesTextByPaste(OutputHostResolve()),
			"an ordinary application takes typed text")
		AssertFalse(OutputHostTakesTextByPaste(_OutputHostInvalidReceipt("identity_unavailable")),
			"an unknown host keeps the typed text")
	} finally {
		SetTimer(_TextSenderStartClipboard, 0)
		_TEXT_CLIPBOARD_QUEUE := SavedQueue
		_AHK_SendText := SavedSendText
		SimulateRegularApp()
	}
}
Test("TextSender: auto mode pastes in Notepad and types elsewhere (llm-accept-notepad-paste)",
	_LAIET_AutoModePastesInNotepadOnly)

; The incident's third slot erased sixteen characters before its fifty-character
; correction. These recordings qualify acceptance and atomic batch construction,
; not the clipboard worker or Notepad's asynchronous consumption of that batch.
_LAIET_RewritePaste(Body) {
	global _TEXT_CLIPBOARD_QUEUE, _TEXT_CLIPBOARD_BUSY
	global _Stub_OutputHostExe, _Stub_OutputHostTitle
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE, _OUTPUT_HOST_METADATA_PROBE
	global _OUTPUT_HOST_TITLE_PROBE, _OUTPUT_HOST_RESOLVE_SERIAL
	SavedQueue := _TEXT_CLIPBOARD_QUEUE
	SavedHost := { App: KLHook.prev_app, Title: KLHook.prev_title,
		Exe: _Stub_OutputHostExe, StubTitle: _Stub_OutputHostTitle,
		Cache: _OUTPUT_HOST_CACHE, Identity: _OUTPUT_HOST_IDENTITY_PROBE,
		Metadata: _OUTPUT_HOST_METADATA_PROBE, TitleProbe: _OUTPUT_HOST_TITLE_PROBE,
		Serial: _OUTPUT_HOST_RESOLVE_SERIAL }
	AssertFalse(_TEXT_CLIPBOARD_BUSY, "the passive rewrite fixture cannot adopt a live clipboard worker")
	try {
		SimulateNotepadActive()
		_TEXT_CLIPBOARD_QUEUE := []
		_LAIET_Run(Body)
	} finally {
		try SetTimer(_TextSenderStartClipboard, 0)
		finally {
			_TEXT_CLIPBOARD_QUEUE := SavedQueue
			KLHook.prev_app := SavedHost.App
			KLHook.prev_title := SavedHost.Title
			_Stub_OutputHostExe := SavedHost.Exe
			_Stub_OutputHostTitle := SavedHost.StubTitle
			_OUTPUT_HOST_CACHE := SavedHost.Cache
			_OUTPUT_HOST_IDENTITY_PROBE := SavedHost.Identity
			_OUTPUT_HOST_METADATA_PROBE := SavedHost.Metadata
			_OUTPUT_HOST_TITLE_PROBE := SavedHost.TitleProbe
			_OUTPUT_HOST_RESOLVE_SERIAL := SavedHost.Serial
		}
	}
}

_LAIET_ConfigureRewrite(Record, Text, DeletedText, Span, Count) {
	Slot := { Text: Text, Deletes: Count, DeletedText: DeletedText, RewriteSpan: Span }
	Record.Slots := ["unused first slot", "unused second slot", Slot]
	Record.ActiveIdx := 3
	Record.Lifecycle.Slots := Record.Slots.Clone()
}

_LAIET_DispatchRewriteWithoutWorker() {
	; Keep the queued worker from running between dispatch and its cancellation.
	; Only the actual acceptance and recording ports run in this short scope.
	PreviousCritical := Critical("On")
	try {
		return _LLM_Accept_ClaimAndDispatch(LLM_Tooltip_GetAcceptSnapshot())
	} finally {
		try SetTimer(_TextSenderStartClipboard, 0)
		finally Critical(PreviousCritical)
	}
}

_LAIET_RecordQueuedRewrite(Sent, Record, Text, Count, ExpectedBuffer) {
	global _TEXT_CLIPBOARD_QUEUE, _AHK_SendInput, _LLM_Bridge_Buffer, TEXT_SENDER_SEND_LEVEL
	AssertEqual(0, Sent.Length, "the rewrite must wait for its clipboard request instead of typing text")
	AssertEqual(1, _TEXT_CLIPBOARD_QUEUE.Length, "the accepted rewrite queues exactly one paste")
	Request := _TEXT_CLIPBOARD_QUEUE.RemoveAt(1)
	AssertEqual(Text, Request.Text, "the complete accepted correction is the queued clipboard payload")
	AssertEqual(Count, Request.Opts["erase_before"], "the chosen slot's erasure reaches TextSend unchanged")
	AssertTrue(_TextSenderHasAtomicHooks(Request.Opts), "erasure must retain admission and atomic commit owners")
	; This is the same production atomic output owner exercised by the existing
	; zero-erasure test. Clipboard write/wait/restore are deliberately not invoked.
	Result := _TextSenderRunAtomicOutput(
		_AHK_SendInput.Bind(_TextSenderErasePrefix(Request.Opts) . "^v"),
		Request.Opts, "clipboard paste")
	AssertTrue(Result.Ok, "the recording atomic output must succeed before completion is reported")
	AssertEqual("", Result.ErrorMessage, "the recording output has no post-output warning")
	Request.Callback.Call(Result.Ok, Result.ErrorMessage)
	AssertEqual(1, Sent.Length, "erasure and paste are emitted in a single recorded batch")
	AssertEqual("{Backspace " . Count . "}^v", Sent[1].Keys,
		"the recorded rewrite batch must include both the exact erasure and Ctrl+V")
	AssertEqual(TEXT_SENDER_SEND_LEVEL, Sent[1].Level, "rewriting preserves the sender's SendLevel")
	AssertEqual(2, A_SendLevel, "the accepting thread's SendLevel is restored")
	AssertEqual(ExpectedBuffer, _LLM_Bridge_Buffer, "the RAM mirror applies deletion and replacement once")
	AssertEqual("accepted", Record.Lifecycle.Outcome, "only the completed recording retires the offer as accepted")
}

_LAIET_NotepadIncidentCorrectionByPaste() {
	_LAIET_RewritePaste(_Body)
	_Body(Sent, Record) {
		global _LLM_Bridge_Buffer
		Typed := "napéoléon is the"
		Correction := "Napoleon is the greatest emperor in French history"
		AssertEqual(16, StrLen(Typed), "the reported deletion has sixteen UTF-16 units and codepoints")
		AssertEqual(50, StrLen(Correction), "the reported accepted third slot contains fifty characters")
		_LLM_Bridge_Buffer := Typed
		_LAIET_ConfigureRewrite(Record, Correction, Typed, Typed, 16)
		SendLevel(2)
		AssertTrue(_LAIET_DispatchRewriteWithoutWorker(), "the shown third rewrite slot is claimed and dispatched")
		AssertEqual("claimed", Record.Lifecycle.Outcome, "the clipboard request must not retire before output")
		AssertEqual(Typed, _LLM_Bridge_Buffer, "queued erasure cannot update the mirror before output")
		_LAIET_RecordQueuedRewrite(Sent, Record, Correction, 16, Correction)
	}
}
Test("LLM accept: the Notepad incident's third correction queues sixteen erasures and paste (llm-rewrite-paste-recording)",
	_LAIET_NotepadIncidentCorrectionByPaste)

_LAIET_NotepadScalarErasureByPaste() {
	_LAIET_RewritePaste(_Body)
	_Body(Sent, Record) {
		global _LLM_Bridge_Buffer
		Deleted := "i" . Chr(0x1F600)
		Span := "Je sui" . Chr(0x1F600)
		Correction := "is déjà allé."
		AssertEqual(3, StrLen(Deleted), "the deleted suffix occupies three UTF-16 units")
		_LLM_Bridge_Buffer := "Avant. " . Span
		_LAIET_ConfigureRewrite(Record, Correction, Deleted, Span, 2)
		SendLevel(2)
		AssertTrue(_LAIET_DispatchRewriteWithoutWorker(), "the supplementary-character rewrite is dispatched")
		_LAIET_RecordQueuedRewrite(Sent, Record, Correction, 2, "Avant. Je suis déjà allé.")
	}
}
Test("LLM accept: Notepad rewrite erases codepoints while its mirror deletes UTF-16 units (llm-rewrite-paste-recording)",
	_LAIET_NotepadScalarErasureByPaste)

_LAIET_NotepadStaleRewriteNeverQueuesPaste() {
	_LAIET_RewritePaste(_Body)
	_Body(Sent, Record) {
		global _LLM_Bridge_Buffer, _TEXT_CLIPBOARD_QUEUE
		Typed := "napéoléon is the"
		_LLM_Bridge_Buffer := Typed . " changed"
		_LAIET_ConfigureRewrite(Record,
			"Napoleon is the greatest emperor in French history", Typed, Typed, 16)
		SendLevel(2)
		AssertTrue(_LAIET_DispatchRewriteWithoutWorker(), "claim and dispatch are distinct from injection success")
		AssertEqual(0, Sent.Length, "a stale correction must neither erase nor send a paste")
		AssertEqual(0, _TEXT_CLIPBOARD_QUEUE.Length, "a changed rewrite span must not enter the clipboard FIFO")
		AssertEqual(Typed . " changed", _LLM_Bridge_Buffer, "a refused rewrite preserves the changed text")
		AssertEqual("dismissed", Record.Lifecycle.Outcome, "a refused correction cannot be recorded as accepted")
	}
}
Test("LLM accept: a stale Notepad correction refuses erasure before entering the clipboard FIFO (llm-rewrite-paste-recording)",
	_LAIET_NotepadStaleRewriteNeverQueuesPaste)
