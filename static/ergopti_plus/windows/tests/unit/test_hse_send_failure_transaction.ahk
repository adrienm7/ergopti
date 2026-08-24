; tests/unit/test_hse_send_failure_transaction.ahk

; ==============================================================================
; MODULE: HSE Send-Failure Transaction Regression Tests
; DESCRIPTION:
; Proves that every hotstring output path treats sender success as the commit
; boundary for engine, preview, ring, and fired-metric state. The AHK-04 defect
; caught send failures inside the primitive but its callers still published a
; fictional expansion after no bytes reached the foreground application.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Transaction harness =======
; ======================================
; ======================================

global _AHK04_SendCalls := []
global _AHK04_SendVerdict := true
global _AHK04_SendVerdicts := []

_AHK04_SendHook(Name, Args*) {
	global _AHK04_SendCalls, _AHK04_SendVerdict, _AHK04_SendVerdicts
	_AHK04_SendCalls.Push({ Name: Name, Args: Args })
	if (_AHK04_SendCalls.Length <= _AHK04_SendVerdicts.Length)
		return _AHK04_SendVerdicts[_AHK04_SendCalls.Length]
	return _AHK04_SendVerdict
}

_AHK04_SetSendVerdict(Verdict) {
	global _AHK04_SendCalls, _AHK04_SendVerdict, _AHK04_SendVerdicts
	_AHK04_SendCalls := []
	_AHK04_SendVerdict := Verdict
	_AHK04_SendVerdicts := []
	return
}

_AHK04_SetSendVerdicts(Verdicts*) {
	global _AHK04_SendCalls, _AHK04_SendVerdict, _AHK04_SendVerdicts
	_AHK04_SendCalls := []
	_AHK04_SendVerdict := true
	_AHK04_SendVerdicts := Verdicts
}

_AHK04_CaptureState() {
	global _SendHook, _ALTGR_KANA_FIXUP, HSE_Buffer, HSE_StartIsWordBoundary
	global HSE_TypoNbspStripped, HSE_LastMatch, _PrefixBuffer
	global _PrefixWatcherSuppressed, _KLLastShownSuggestion
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _Stub_LastChars, LastSentCharacterKeyTime
	global _DeadKeyInputHook, _OneShotShiftInputHook, _SpaceHoldInputHook
	return {
		SendHook: _SendHook,
		AltGrFixup: _ALTGR_KANA_FIXUP,
		HseBuffer: HSE_Buffer,
		HseBoundary: HSE_StartIsWordBoundary,
		TypoNbsp: HSE_TypoNbspStripped,
		LastMatch: HSE_LastMatch,
		PrefixBuffer: _PrefixBuffer,
		PrefixSuppressed: _PrefixWatcherSuppressed,
		LastSuggestion: _KLLastShownSuggestion,
		Ring: _LSC_RING.Clone(),
		RingCursor: _LSC_CURSOR,
		RingLength: _LSC_LEN,
		StubLastChars: _Stub_LastChars.Clone(),
		LastSentTimes: LastSentCharacterKeyTime.Clone(),
		FireQueue: _HSE_FireLogQueue.Clone(),
		FireScheduled: _HSE_FireLogScheduled,
		PreviousApp: KLHook.prev_app,
		; run_all deliberately does not include the three interactive remap modules.
		; Preserve their globals only when the active harness actually assigned them;
		; reading an unset declared global raises before any assertion can run.
		DeadKeyHook: IsSet(_DeadKeyInputHook)
			? { Assigned: true, Value: _DeadKeyInputHook } : { Assigned: false },
		OneShotShiftHook: IsSet(_OneShotShiftInputHook)
			? { Assigned: true, Value: _OneShotShiftInputHook } : { Assigned: false },
		SpaceHoldHook: IsSet(_SpaceHoldInputHook)
			? { Assigned: true, Value: _SpaceHoldInputHook } : { Assigned: false },
		SynthActive: Keylogger.synth_active,
		SynthType: Keylogger.synth_type,
		SynthPrivate: Keylogger.synth_private
	}
}

_AHK04_RestoreState(State) {
	global _SendHook, _ALTGR_KANA_FIXUP, HSE_Buffer, HSE_StartIsWordBoundary
	global HSE_TypoNbspStripped, HSE_LastMatch, _PrefixBuffer
	global _PrefixWatcherSuppressed, _KLLastShownSuggestion
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _Stub_LastChars, LastSentCharacterKeyTime
	global _DeadKeyInputHook, _OneShotShiftInputHook, _SpaceHoldInputHook
	_SendHook := State.SendHook
	_ALTGR_KANA_FIXUP := State.AltGrFixup
	HSE_Buffer := State.HseBuffer
	HSE_StartIsWordBoundary := State.HseBoundary
	HSE_TypoNbspStripped := State.TypoNbsp
	HSE_LastMatch := State.LastMatch
	_PrefixBuffer := State.PrefixBuffer
	_PrefixWatcherSuppressed := State.PrefixSuppressed
	_KLLastShownSuggestion := State.LastSuggestion
	_LSC_RING := State.Ring
	_LSC_CURSOR := State.RingCursor
	_LSC_LEN := State.RingLength
	_Stub_LastChars := State.StubLastChars
	LastSentCharacterKeyTime := State.LastSentTimes
	_HSE_FireLogQueue := State.FireQueue
	_HSE_FireLogScheduled := State.FireScheduled
	KLHook.prev_app := State.PreviousApp
	if State.DeadKeyHook.Assigned
		_DeadKeyInputHook := State.DeadKeyHook.Value
	if State.OneShotShiftHook.Assigned
		_OneShotShiftInputHook := State.OneShotShiftHook.Value
	if State.SpaceHoldHook.Assigned
		_SpaceHoldInputHook := State.SpaceHoldHook.Value
	Keylogger.synth_active := State.SynthActive
	Keylogger.synth_type := State.SynthType
	Keylogger.synth_private := State.SynthPrivate
}

_AHK04_RunIsolated(Callback) {
	global _SendHook, _ALTGR_KANA_FIXUP, HSE_TypoNbspStripped
	global HSE_LastMatch, _PrefixWatcherSuppressed
	global _HSE_FireLogQueue, _HSE_FireLogScheduled, HSE_SUPPRESS_RELEASE_DELAY_MS
	global _Stub_LastChars, LastSentCharacterKeyTime
	global _DeadKeyInputHook, _OneShotShiftInputHook, _SpaceHoldInputHook
	PreviousCritical := Critical("On")
	; Drain releases owned by the preceding shared-suite test before snapshotting;
	; otherwise restoring a captured non-zero depth would resurrect state whose
	; one-shot release fired while this test's isolated zero was installed.
	Critical("Off")
	Sleep(HSE_SUPPRESS_RELEASE_DELAY_MS + 20)
	Critical("On")
	State := _AHK04_CaptureState()
	try {
		_SendHook := _AHK04_SendHook
		_ALTGR_KANA_FIXUP := false
		HSE_TypoNbspStripped := false
		HSE_LastMatch := ""
		_PrefixWatcherSuppressed := 0
		_HSE_FireLogQueue := []
		; Keep the real drain timer disarmed while tests inspect exact queue counts.
		_HSE_FireLogScheduled := true
		KLHook.prev_app := "ahk04-test.exe"
		OutputHostResolverPrimeForTest("ahk04-test.exe")
		_Stub_LastChars := []
		LastSentCharacterKeyTime := Map()
		; Ring commits must not be masked by unrelated input hooks left active by a
		; preceding test in the shared run_all process.
		if State.DeadKeyHook.Assigned
			_DeadKeyInputHook := ""
		if State.OneShotShiftHook.Assigned
			_OneShotShiftInputHook := ""
		if State.SpaceHoldHook.Assigned
			_SpaceHoldInputHook := ""
		Keylogger.synth_active := 0
		Keylogger.synth_type := "none"
		Keylogger.synth_private := false
		Callback.Call()
	} finally {
		; Successful fires defer their suppression/synthetic release by 60 ms. Let
		; those one-shot callbacks drain against the isolated state before restoring
		; a possibly non-zero depth owned by another test.
		Critical("Off")
		Sleep(HSE_SUPPRESS_RELEASE_DELAY_MS + 20)
		Critical("On")
		_AHK04_RestoreState(State)
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
}

_AHK04_NormalSpec() {
	return {
		Trigger: "ab",
		Length: 2,
		Replacement: "Z",
		OnlyText: true,
		FinalResult: true,
		Category: "autocorrection",
		Section: "common",
		IsPrivate: false
	}
}



; ===========================================
; ===== 1.1) Sender verdict propagation =====
; ===========================================

_AHK04_SendPrimitivesImpl() {
	global _AHK04_SendCalls
	AssertEqual(false, _SendVerdictSucceeded(0),
		"only an explicit Integer zero must mean sender failure")
	AssertEqual(true, _SendVerdictSucceeded("0"),
		"the String token 0 must not coerce to false in AHK v2")
	AssertEqual(true, _SendVerdictSucceeded(""),
		"legacy recorder hooks with no explicit return must remain successful")
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdict("0")
	AssertEqual(true, SendNewResult("Q"),
		"a hook returning the String token 0 must report successful output")
	AssertEqual("Q", GetLastSentCharacterAt(-1),
		"a successful String 0 verdict must commit the emitted character to the ring")
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdict(0)
	AssertEqual(false, SendNewResult("Q"),
		"a hook returning Integer zero must report output failure")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"an Integer-zero failure must leave the ring unchanged")
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdict(false)
	AssertEqual(false, SendNewResult("Q"),
		"SendNewResult must propagate an explicit false hook verdict")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"failed SendNewResult must not advance the output ring")
	AssertEqual(false, SendFinalResult("Q"),
		"SendFinalResult must propagate an explicit false hook verdict")
	AssertEqual(false, SendInstant("Q", "{BackSpace}"),
		"SendInstant must propagate an explicit false hook verdict")
	AssertEqual(3, _AHK04_SendCalls.Length,
		"each primitive must report one and only one attempted send")
}

_AHK04_SendPrimitivesPropagateFalse() {
	_AHK04_RunIsolated(_AHK04_SendPrimitivesImpl)
}



; =============================================
; ===== 1.2) Normal HSE fire transactions =====
; =============================================

_AHK04_NormalDispatchImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls
	Spec := _AHK04_NormalSpec()

	for Vector in [
		{ Name: "star", EndChar: "", Buffer: "xxab" },
		{ Name: "end-char", EndChar: " ", Buffer: "xxab " }
	] {
		_LSCResetFrom(["seed"])
		HSE_Buffer := Vector.Buffer
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "preview-" . Vector.Name
		_AHK04_SetSendVerdict(false)
		Fired := HSE_DispatchMatch(Spec, Vector.EndChar)
		AssertEqual(false, Fired,
			Vector.Name . " send failure must be reported as a declined fire")
		AssertEqual(Vector.Buffer, HSE_Buffer,
			Vector.Name . " send failure must leave the engine buffer unchanged")
		AssertEqual("preview-" . Vector.Name, _PrefixBuffer,
			Vector.Name . " send failure must leave the preview buffer unchanged")
		AssertEqual("seed", GetLastSentCharacterAt(-1),
			Vector.Name . " send failure must not advance the output ring")
		AssertEqual(1, _AHK04_SendCalls.Length,
			Vector.Name . " must attempt one atomic output burst")
		AssertEqual("SendFinalResult", _AHK04_SendCalls[1].Name,
			Vector.Name . " must route its atomic burst through the status-bearing sender")
	}

	_LSCResetFrom(["seed"])
	HSE_Buffer := "xxab"
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "xxab"
	_AHK04_SetSendVerdict(true)
	AssertEqual(true, HSE_DispatchMatch(Spec, ""),
		"a successful atomic send must publish one real fire")
	AssertEqual("xxZ", HSE_Buffer,
		"successful output must apply the engine edit exactly once")
	AssertEqual("", _PrefixBuffer,
		"successful output must consume the old preview exactly once")
	AssertEqual("Z", GetLastSentCharacterAt(-1),
		"successful output must advance the ring to the emitted character")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"a successful normal fire must remain one atomic send")

	KLHook.prev_app := "notepad.exe"
	OutputHostResolverPrimeForTest("notepad.exe")
	_LSCResetFrom(["seed"])
	HSE_Buffer := "ab"
	_PrefixBuffer := "ab"
	_AHK04_SetSendVerdict(false)
	AssertEqual(false, HSE_DispatchMatch(Spec, ""),
		"Notepad clipboard failure must decline instead of publishing a fire")
	AssertEqual("ab", HSE_Buffer,
		"Notepad clipboard failure must not rewrite the engine buffer")
	AssertEqual("ab", _PrefixBuffer,
		"Notepad clipboard failure must not consume the preview")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"Notepad clipboard failure must not advance the ring")
	AssertEqual("SendInstant", _AHK04_SendCalls[1].Name,
		"Notepad must use the status-bearing clipboard sender")
	AssertEqual("{BackSpace 2}", _AHK04_SendCalls[1].Args[2],
		"Notepad must prepare the payload before injecting its atomic erase prefix")
}

_AHK04_NormalDispatchCommitsOnlyAfterSend() {
	_AHK04_RunIsolated(_AHK04_NormalDispatchImpl)
}

_AHK04_NotepadSendModeImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls
	Spec := _AHK04_NormalSpec()
	Spec.OnlyText := false
	Spec.Replacement := '""{Left}'
	KLHook.prev_app := "notepad.exe"
	OutputHostResolverPrimeForTest("notepad.exe")
	HSE_Buffer := "ab"
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "ab"
	_AHK04_SetSendVerdict(true)

	AssertEqual(true, HSE_DispatchMatch(Spec, ""),
		"a Notepad Send-key expansion must still produce its requested effect")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"the Notepad Send-key expansion must remain one atomic output burst")
	AssertEqual("SendFinalResult", _AHK04_SendCalls[1].Name,
		"OnlyText=false must use the interpreted SendInput route, not literal clipboard paste")
	AssertEqual('{BackSpace 2}""{Left}', _AHK04_SendCalls[1].Args[1],
		"the one burst must erase the trigger, type the quotes, then execute Left")
	AssertEqual("", HSE_Buffer,
		"Send-key syntax moves the caret, so the engine must clear instead of storing the literal {Left} token")
	AssertEqual("", GetLastSentCharacterAt(-1),
		"the last-sent ring must not claim that the final '}' token was emitted as text")
}

_AHK04_NotepadPreservesSendMode() {
	_AHK04_RunIsolated(_AHK04_NotepadSendModeImpl)
}



; ======================================================
; ===== 1.3) AHK-002 functional host ownership ========
; ======================================================

_AHK002_MetricsOffNotepadUsesClipboardImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls, _OHR_IdentityReads
	MetricsShortcuts.enabled := false
	KLHook.prev_app := ""
	_OHR_Reset("notepad.exe", 1401, 2401, "Untitled - Notepad")
	HSE_Buffer := "ab"
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "ab"
	_AHK04_SetSendVerdict(true)

	AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), ""),
		"metrics-off Notepad must still publish a real expansion")
	AssertEqual(1, _AHK04_SendCalls.Length)
	AssertEqual("SendInstant", _AHK04_SendCalls[1].Name,
		"the exact output-host receipt must select the Notepad clipboard route")
	AssertEqual(2, _OHR_IdentityReads,
		"sender selection must acquire one initial/final foreground receipt")
}

_AHK002_MetricsOffNotepadUsesClipboard() {
	SavedEnabled := MetricsShortcuts.enabled
	try _AHK04_RunIsolated(_AHK002_MetricsOffNotepadUsesClipboardImpl)
	finally {
		MetricsShortcuts.enabled := SavedEnabled
		_Stub_SetOutputHost("test.exe", "Test App")
	}
}
Test("output host: metrics-off Notepad uses clipboard (ahk-002)",
	_AHK002_MetricsOffNotepadUsesClipboard)

_AHK002_StableCodeWindowBecomesTerminalImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls, _OHR_IdentityReads
	global _HSE_TerminalOwner, _PrefixInputContextGeneration
	MetricsShortcuts.enabled := false
	KLHook.prev_app := ""
	_OHR_Reset("Code.exe", 1501, 2501, "Codebuff")
	HSE_Buffer := "ab"
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "ab"
	_AHK04_SetSendVerdict(true)

	AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), ""),
		"the fresh Codebuff title must select the terminal transaction")
	AssertTrue(_HSE_TerminalOwner is Map,
		"terminal routing must publish a deferred transaction owner")
	AssertEqual(0, _AHK04_SendCalls.Length,
		"classification must not execute the deferred sender inline")
	AssertEqual(2, _OHR_IdentityReads,
		"classification and owner creation must reuse one foreground receipt")

	SavedGeneration := _PrefixInputContextGeneration
	try {
		_PrefixInputContextGeneration += 1
		PreviousCritical := Critical("Off")
		try Sleep(_HSE_TerminalOwner["DelayMs"] + 30)
		finally Critical(PreviousCritical)
		AssertFalse(_HSE_TerminalOwner is Map,
			"the deliberately invalidated fixture owner must clean itself up")
		AssertEqual(0, _AHK04_SendCalls.Length,
			"the invalidated owner must emit no terminal output")
	} finally {
		_PrefixInputContextGeneration := SavedGeneration
	}
}

_AHK002_StableCodeWindowBecomesTerminal() {
	SavedEnabled := MetricsShortcuts.enabled
	try _AHK04_RunIsolated(_AHK002_StableCodeWindowBecomesTerminalImpl)
	finally {
		MetricsShortcuts.enabled := SavedEnabled
		_Stub_SetOutputHost("test.exe", "Test App")
	}
}
Test("output host: same Code window can become terminal (ahk-002)",
	_AHK002_StableCodeWindowBecomesTerminal)



; ==========================================
; ===== 1.4) Raw callback transactions =====
; ==========================================

_AHK04_EllipsisRawCallback(*) {
	if SendNewResult("{BackSpace 3}…", false)
		return { Ok: true, Bs: 3, Ins: "…" }
	return { Ok: false, Bs: 0, Ins: "" }
}

_AHK04_DeadkeyRawCallback(MappedValue) {
	if SendNewResult("{BackSpace 2}{Text}" . MappedValue, false)
		return { Ok: true, Bs: 2, Ins: MappedValue }
	return { Ok: false, Bs: 0, Ins: "" }
}

_AHK04_RawCallbacksImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls
	EllipsisSpec := { RawCallback: true, Callback: _AHK04_EllipsisRawCallback, IsPrivate: false }

	_LSCResetFrom(["a", ".", ".", "."])
	HSE_Buffer := "a..."
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "a..."
	_AHK04_SetSendVerdict(false)
	AssertEqual(false, HSE_DispatchMatch(EllipsisSpec, ""),
		"failed ellipsis output must report no fire")
	AssertEqual("a...", HSE_Buffer,
		"failed ellipsis output must not publish its {Ok, Bs, Ins} transaction")
	AssertEqual("a...", _PrefixBuffer,
		"failed ellipsis output must not consume the preview")
	AssertEqual(".", GetLastSentCharacterAt(-1),
		"failed ellipsis output must not advance the ring")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"ellipsis must use one status-bearing output burst")

	_LSCResetFrom(["a", ".", ".", "."])
	HSE_Buffer := "a..."
	_PrefixBuffer := "a..."
	_AHK04_SetSendVerdict(true)
	AssertEqual(true, HSE_DispatchMatch(EllipsisSpec, "", &RawEffect),
		"successful ellipsis output must report one fire")
	Assert(IsObject(RawEffect) and RawEffect.HasOwnProp("KnownBoundaryAfter"),
		"a successful raw callback must publish the same canonical effect as a normal replacement")
	AssertEqual(false, RawEffect.KnownBoundaryAfter,
		"an inserted ellipsis is not a proven word boundary")
	AssertEqual("a…", HSE_Buffer,
		"successful ellipsis output must apply its effect exactly once")
	AssertEqual("", _PrefixBuffer,
		"successful ellipsis output must consume the preview")
	RawDecision := _PrefixPostFireDecision(RawEffect, HSE_Buffer, 64)
	AssertEqual("a…", RawDecision.Buffer,
		"the prefix watcher must be able to resume from the raw callback's exact screen state")
	AssertEqual(true, RawDecision.Schedule,
		"raw callback output must be checked for a cascade instead of being reset unconditionally")
	AssertEqual("…", GetLastSentCharacterAt(-1),
		"successful ellipsis output must advance the ring once")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"successful ellipsis output must remain one burst")

	_LSCResetFrom([" ", "ê", "x"])
	_AHK04_SetSendVerdict(false)
	DeadkeyFailure := _AHK04_DeadkeyRawCallback("★")
	AssertEqual(false, DeadkeyFailure.Ok,
		"failed deadkey output must return an explicit false transaction verdict")
	AssertEqual(0, DeadkeyFailure.Bs,
		"failed deadkey output must expose no fictional backspace effect")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"deadkey erase and replacement must be one status-bearing burst")

	_LSCResetFrom([" ", "ê", "x"])
	_AHK04_SetSendVerdict(true)
	DeadkeySuccess := _AHK04_DeadkeyRawCallback("★")
	AssertEqual(true, DeadkeySuccess.Ok,
		"successful deadkey output must return an explicit true transaction verdict")
	AssertEqual(2, DeadkeySuccess.Bs,
		"successful deadkey output must declare its proven buffer effect")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"successful deadkey output must remain one burst")
}

_AHK04_RawCallbacksCommitOnlyProvenEffects() {
	_AHK04_RunIsolated(_AHK04_RawCallbacksImpl)
}



; =========================================
; ===== 1.4) UIA wrapper transactions =====
; =========================================

_AHK04_UIAWrapperImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls
	Pair := Map("left", "(", "right", ")")

	HSE_Buffer := "engine"
	HSE_StartIsWordBoundary := false
	_PrefixBuffer := "preview"
	_AHK04_SetSendVerdict(false)
	AssertEqual(false, _PrefixTryWrapSelection("selection", Pair),
		"failed UIA wrapper output must leave the physical symbol as fallback")
	AssertEqual("engine", HSE_Buffer,
		"failed UIA wrapper output must not reset the engine buffer")
	AssertEqual("preview", _PrefixBuffer,
		"failed UIA wrapper output must not reset the preview buffer")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"UIA wrapping must attempt exactly one output transaction")
	AssertEqual("SendInstant", _AHK04_SendCalls[1].Name,
		"UIA wrapping must use the status-bearing clipboard sender")
	AssertEqual("{BackSpace}", _AHK04_SendCalls[1].Args[2],
		"the physical symbol erase must be an atomic prefix prepared after the payload")

	HSE_Buffer := "engine"
	HSE_StartIsWordBoundary := false
	_PrefixBuffer := "preview"
	_AHK04_SetSendVerdict(true)
	AssertEqual(true, _PrefixTryWrapSelection("selection", Pair),
		"successful UIA wrapper output must publish success")
	AssertEqual("", HSE_Buffer,
		"successful UIA wrapping must reset the engine context")
	AssertEqual("", _PrefixBuffer,
		"successful UIA wrapping must reset the preview context")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"successful UIA wrapping must remain one transaction")
}

_AHK04_UIAWrapperIsLosslessOnFailure() {
	_AHK04_RunIsolated(_AHK04_UIAWrapperImpl)
}



; =========================================
; ===== 1.5) Fired-metric transaction =====
; =========================================

_AHK04_FireMetricImpl() {
	global _HSE_FireLogQueue, _AHK04_SendCalls, _PrefixWatcherSuppressed
	; Fail each of the legacy recorder's three stages independently. The ring may
	; reflect only output that the hook explicitly confirmed; a fire metric may
	; appear only after erase, replacement, and end character all succeeded.
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdicts(false)
	Fired := _HotstringDispatch("R", " ", "{BackSpace 2}", "b", true, false,
		0, 2, "ab", "autocorrection", "common", false)
	AssertEqual(false, Fired,
		"the recorder callback must propagate a failed first send")
	AssertEqual(1, _AHK04_SendCalls.Length,
		"a failed erase must abort before replacement or end-character output")
	AssertEqual(0, _HSE_FireLogQueue.Length,
		"failed output must enqueue zero fired metrics")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"a failed first stage must leave the ring unchanged")
	AssertEqual(0, _PrefixWatcherSuppressed,
		"a failed first stage must release prefix suppression synchronously")
	AssertEqual(0, Keylogger.synth_active,
		"a failed first stage must release synthetic attribution synchronously")

	_HSE_FireLogQueue := []
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdicts(true, false)
	Fired := _HotstringDispatch("R", " ", "{BackSpace 2}", "b", true, false,
		0, 2, "ab", "autocorrection", "common", false)
	AssertEqual(false, Fired,
		"the recorder callback must propagate a failed replacement send")
	AssertEqual(2, _AHK04_SendCalls.Length,
		"a failed replacement must abort before end-character output")
	AssertEqual(0, _HSE_FireLogQueue.Length,
		"erase-only partial output must enqueue zero fired metrics")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"the erase stage is intentionally excluded from the emitted-character ring")
	AssertEqual(0, _PrefixWatcherSuppressed,
		"a failed second stage must release prefix suppression synchronously")
	AssertEqual(0, Keylogger.synth_active,
		"a failed second stage must release synthetic attribution synchronously")

	_HSE_FireLogQueue := []
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdicts(true, true, false)
	Fired := _HotstringDispatch("R", " ", "{BackSpace 2}", "b", true, false,
		0, 2, "ab", "autocorrection", "common", false)
	AssertEqual(false, Fired,
		"the recorder callback must propagate a failed end-character send")
	AssertEqual(3, _AHK04_SendCalls.Length,
		"end-character failure must occur only after erase and replacement succeeded")
	AssertEqual(0, _HSE_FireLogQueue.Length,
		"replacement-only partial output must enqueue zero fired metrics")
	AssertEqual("R", GetLastSentCharacterAt(-1),
		"the ring must retain only the replacement stage proven to reach the screen")
	AssertEqual(0, _PrefixWatcherSuppressed,
		"a failed third stage must release prefix suppression synchronously")
	AssertEqual(0, Keylogger.synth_active,
		"a failed third stage must release synthetic attribution synchronously")

	_HSE_FireLogQueue := []
	_LSCResetFrom(["seed"])
	_AHK04_SetSendVerdicts(true, true, true)
	Fired := _HotstringDispatch("R", " ", "{BackSpace 2}", "b", true, false,
		0, 2, "ab", "autocorrection", "common", false)
	AssertEqual(true, Fired,
		"successful callback output must report one fire")
	AssertEqual(1, _HSE_FireLogQueue.Length,
		"successful output must enqueue exactly one fired metric")
	AssertEqual(3, _AHK04_SendCalls.Length,
		"the legacy recorder path must preserve its three ordered send stages")
	AssertEqual(" ", GetLastSentCharacterAt(-1),
		"full success must commit the final end character to the ring")
}

_AHK04_FireMetricsFollowTheSendVerdict() {
	_AHK04_RunIsolated(_AHK04_FireMetricImpl)
}

Test("hotstrings: send primitives propagate false (AHK-04-send-transaction)",
	_AHK04_SendPrimitivesPropagateFalse)
Test("hotstrings: star, end-char and Notepad state commits follow output (AHK-04-send-transaction)",
	_AHK04_NormalDispatchCommitsOnlyAfterSend)
Test("hotstrings: Notepad preserves interpreted Send-key payloads (notepad-onlytext-policy-20260813)",
	_AHK04_NotepadPreservesSendMode)
Test("hotstrings: raw callbacks publish only proven effects (AHK-04-send-transaction)",
	_AHK04_RawCallbacksCommitOnlyProvenEffects)
Test("hotstrings: UIA wrapper failure preserves the physical fallback (AHK-04-send-transaction)",
	_AHK04_UIAWrapperIsLosslessOnFailure)
Test("hotstrings: fired metrics follow the sender verdict (AHK-04-send-transaction)",
	_AHK04_FireMetricsFollowTheSendVerdict)
