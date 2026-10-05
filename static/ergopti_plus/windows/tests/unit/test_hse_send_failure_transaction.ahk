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
		SynthOwners: Keylogger.synth_owners,
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
	Keylogger.synth_owners := State.SynthOwners
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
		Keylogger.synth_owners := []
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
	AssertEqual(false, HSE_DispatchMatch(Spec, "", , false, _HNP_InlineSend.Bind(false)),
		"Notepad native refusal must decline instead of publishing a fire")
	AssertEqual("ab", HSE_Buffer,
		"Notepad native refusal must not rewrite the engine buffer")
	AssertEqual("ab", _PrefixBuffer,
		"Notepad native refusal must not consume the preview")
	AssertEqual("seed", GetLastSentCharacterAt(-1),
		"Notepad native refusal must not advance the ring")
	AssertEqual("NativeTextSend", _AHK04_SendCalls[1].Name,
		"Notepad must use the native completion-bearing sender")
	AssertEqual("ab", _AHK04_SendCalls[1].Args[2]["deleted_text"],
		"Notepad must submit the actual erased suffix")
}

_AHK04_NormalDispatchCommitsOnlyAfterSend() {
	_HNP_Run(_AHK04_NormalDispatchImpl)
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

_AHK002_MetricsOffNotepadUsesNativeImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _AHK04_SendCalls, _OHR_IdentityReads
	MetricsShortcuts.enabled := false
	KLHook.prev_app := ""
	_OHR_Reset("notepad.exe", 1401, 2401, "Untitled - Notepad")
	HSE_Buffer := "ab"
	HSE_StartIsWordBoundary := true
	_PrefixBuffer := "ab"
	_AHK04_SetSendVerdict(true)

	AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), "", , false, _HNP_InlineSend.Bind(true)) is Map,
		"metrics-off Notepad must still publish a real expansion")
	AssertEqual(1, _AHK04_SendCalls.Length)
	AssertEqual("NativeTextSend", _AHK04_SendCalls[1].Name,
		"the exact output-host receipt must select the Notepad native route")
	AssertEqual(2, _OHR_IdentityReads,
		"sender selection must acquire one initial/final foreground receipt")
}

_AHK002_MetricsOffNotepadUsesNative() {
	SavedEnabled := MetricsShortcuts.enabled
	try _HNP_Run(_AHK002_MetricsOffNotepadUsesNativeImpl)
	finally {
		MetricsShortcuts.enabled := SavedEnabled
		_Stub_SetOutputHost("test.exe", "Test App")
	}
}
Test("output host: metrics-off Notepad uses native completion (ahk-002)",
	_AHK002_MetricsOffNotepadUsesNative)

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

_AHK002_TerminalCaptureAccept(*) {
	return 1
}

_AHK002_TerminalCaptureSnapshot(Token) {
	return Map("token", Token, "phase", 0, "queued", 0, "replayed", 0,
		"last_os_error", 0, "release_kind", 2)
}

_AHK002_StableCodeWindowBecomesTerminal() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerPort
	SavedEnabled := MetricsShortcuts.enabled
	SavedStarted := _LLM_NavEventOwnerStarted
	SavedPort := _LLM_NavEventOwnerPort
	try {
		; AHK-002 owns host classification, not native hook installation. Its
		; Codebuff path must nevertheless cross the real terminal owner boundary
		; now that paced output refuses to run without keyboard capture.
		_LLM_NavEventOwnerStarted := true
		_LLM_NavEventOwnerPort := Map(
			"begin_terminal", _AHK002_TerminalCaptureAccept,
			"commit_terminal", _AHK002_TerminalCaptureAccept,
			"abort_terminal", _AHK002_TerminalCaptureAccept,
			"get_terminal", _AHK002_TerminalCaptureSnapshot)
		_AHK04_RunIsolated(_AHK002_StableCodeWindowBecomesTerminalImpl)
	}
	finally {
		_LLM_NavEventOwnerStarted := SavedStarted
		_LLM_NavEventOwnerPort := SavedPort
		MetricsShortcuts.enabled := SavedEnabled
		_Stub_SetOutputHost("test.exe", "Test App")
	}
}
Test("output host: same Code window can become terminal (ahk-002)",
	_AHK002_StableCodeWindowBecomesTerminal)

_AHK201_SecondaryTerminalMatchesBalanceAfterRefusalImpl() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer
	global _HSE_TerminalOwner, _PrefixWatcherSuppressed
	HeldOwner := Map("Pending", true)
	_HSE_TerminalOwner := HeldOwner
	_OHR_Reset("WindowsTerminal.exe", 1601, 2601, "Terminal")
	loop 3 {
		HSE_Buffer := "ab"
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "ab"
		AssertFalse(HSE_DispatchMatch(_AHK04_NormalSpec(), ""),
			"a secondary terminal match must decline while the first owner is held")
		AssertTrue(_HSE_TerminalOwner == HeldOwner,
			"a refusal must preserve the exact first terminal owner")
		AssertEqual(0, _PrefixWatcherSuppressed,
			"repeated refused matches must balance prefix suppression")
		AssertEqual(0, Keylogger.synth_active,
			"repeated refused matches must balance synthetic ownership")
		AssertEqual("ab", HSE_Buffer,
			"a refused secondary match must not publish canonical output")
		AssertEqual("ab", _PrefixBuffer,
			"a refused secondary match must not retire its preview context")
	}
}

_AHK201_SecondaryTerminalMatchesBalanceAfterRefusal() {
	global _HSE_TerminalOwner
	SavedOwner := _HSE_TerminalOwner
	try _AHK04_RunIsolated(
		_AHK201_SecondaryTerminalMatchesBalanceAfterRefusalImpl)
	finally {
		_HSE_TerminalOwner := SavedOwner
		_Stub_SetOutputHost("test.exe", "Test App")
	}
}
Test("terminal owner: real secondary matches balance after held-owner refusal (ahk2-01)",
	_AHK201_SecondaryTerminalMatchesBalanceAfterRefusal)



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


/** Exercise each canonical boundary publisher through its real returned effect. */
_UBP_PublishBoundary(Mode, Text, ExpectedBoundary) {
	_AHK04_RunIsolated(Body)
	Body() {
		global HSE_Buffer, HSE_StartIsWordBoundary, HSE_WORD_TERMINATORS
		global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding
		SavedTerminators := HSE_WORD_TERMINATORS
		SavedActive := _LLM_Bridge_Active
		SavedAgent := _LLM_Bridge_AgentFeeding
		try {
			HSE_WORD_TERMINATORS := SavedTerminators . Chr(0x1F600)
			_LLM_Bridge_Active := false
			_LLM_Bridge_AgentFeeding := false
			HSE_Buffer := "ab"
			HSE_StartIsWordBoundary := true
			if Mode == "expansion" {
				Effect := HSE_ApplyExpansion({ Length: 2, OnlyText: true }, Text)
			} else if Mode == "callback" {
				Callback(*) => { Ok: true, Bs: 2, Ins: Text }
				Spec := { Callback: Callback, IsPrivate: false }
				AssertTrue(_HSE_DispatchRawCallback(Spec, "", &Effect),
					"the successful recording callback owns its published deletion")
			} else {
				Owner := Map("EraseUnits", 2, "OnlyText", true, "PlainInsertedText", Text,
					"EndCharPart", "", "IsPrivate", false, "Trigger", "ab",
					"ReplacementForLog", Text, "HType", "star", "Category", "fixture", "Section", "fixture")
				if Mode == "terminal-raw" {
					Owner["RawEffect"] := { Ins: Text }
					Effect := _HSE_CommitTerminalRawOwner(Owner)
				} else {
					Effect := _HSE_CommitTerminalOwner(Owner, "")
				}
			}
			AssertTrue(IsObject(Effect), "the actual owner publishes a canonical effect")
			AssertEqual(Text, HSE_Buffer, "the owner commits exactly the recorded replacement")
			AssertEqual(Text, Effect.InsertedText, "the transmitted effect retains the complete scalar")
			AssertEqual(2, Effect.DeleteFromEnd, "the effect retains its actual deletion span")
			AssertEqual(ExpectedBoundary, Effect.KnownBoundaryAfter,
				"only a complete configured delimiter proves the resulting boundary")
			Decision := _PrefixPostFireDecision(Effect, HSE_Buffer, 64)
			ExpectedReset := ExpectedBoundary || Text == ""
			AssertEqual(ExpectedReset, Decision.Reset, "the actual preview decision consumes the owner boundary")
			AssertEqual(ExpectedReset ? "" : Text, Decision.Buffer,
				"a distinct supplementary scalar keeps its exact cascade context")
			AssertEqual(!ExpectedReset, Decision.Schedule, "the cascade is admitted only for retained text")
		} finally {
			_PrefixCancelRender()
			HSE_WORD_TERMINATORS := SavedTerminators
			_LLM_Bridge_Active := SavedActive
			_LLM_Bridge_AgentFeeding := SavedAgent
		}
	}
}
for Mode in ["expansion", "terminal", "terminal-raw", "callback"] {
	Test("publisher unicode-boundary-owner: " . Mode . " rejects a shared low surrogate",
		_UBP_PublishBoundary.Bind(Mode, Chr(0x1FA00), false))
	Test("publisher unicode-boundary-owner: " . Mode . " accepts the actual supplementary delimiter",
		_UBP_PublishBoundary.Bind(Mode, Chr(0x1F600), true))
	Test("publisher unicode-boundary-owner: " . Mode . " retains the empty short-circuit",
		_UBP_PublishBoundary.Bind(Mode, "", false))
}

/** Every successful synthetic tail owns the same complete ring and timing key. */
_UnicodeLedgerAssert(Character) {
	global LastSentCharacterKeyTime
	AssertEqual(Character, GetLastSentCharacterAt(-1), "the ring stores the complete visible scalar")
	AssertTrue(LastSentCharacterKeyTime.Has(Character), "the complete scalar owns its timestamp")
	AssertFalse(IsTimeActivationExpired(Character, 1), "a just-emitted scalar admits a prompt timed completion")
}
_UnicodeLedgerOutput(Mode) {
	if Mode == "paste" || Mode == "paste-endchar"
		return _UnicodeLedgerNativeOutput(Mode == "paste-endchar")

	_AHK04_RunIsolated(Body)
	Body() {
		global HSE_Buffer, HSE_SUPPRESS_RELEASE_DELAY_MS
		Emoji := Chr(0x1F600)
		_LSCResetFrom([])
		_AHK04_SetSendVerdict(true)
		OutputHostResolverPrimeForTest("ledger-fixture.exe")
		if Mode == "primitive" {
			AssertTrue(SendNewResult(Emoji))
		} else {
			Spec := _AHK04_NormalSpec()
			WithEndChar := Mode == "atomic-endchar" || Mode == "paste-endchar"
			Spec.Replacement := WithEndChar ? "R" : Emoji
			HSE_Buffer := "xxab" . (WithEndChar ? Emoji : "")
			AssertTrue(HSE_DispatchMatch(Spec, WithEndChar ? Emoji : ""))
			AssertEqual("xx" . (WithEndChar ? "R" : "") . Emoji, HSE_Buffer, "actual dispatch commits the emitted supplementary result")
		}
		if Mode != "followup" {
			_UnicodeLedgerAssert(Emoji)
			return
		}
		; The first output is atomic and receives no repairing physical OnChar.
		; Admit the next physical completion after the real suppression release.
		Critical("Off")
		Sleep(HSE_SUPPRESS_RELEASE_DELAY_MS + 20)
		Critical("On")
		HSE_Buffer .= "★"
		AppState_TouchLastSentKey("★")
		Next := _MakeHotstringMeta("OK", Emoji . "★", true, true, 1)
		Next.Star := true
		Next.InWord := true
		AssertTrue(HSE_DispatchMatch(Next, ""),
			"a promptly completed real timing gate must see the full previous synthetic scalar")
		AssertEqual("xxOK", HSE_Buffer, "the second actual dispatch commits the timed expansion")
	}
}
_UnicodeLedgerTerminal(Raw, WithTrailing) {
	_AHK04_RunIsolated(Body)
	Body() {
		global HSE_Buffer
		Emoji := Chr(0x1F600)
		Trailing := WithTrailing ? Chr(0x1F601) : ""
		Inserted := WithTrailing ? "R" : Emoji
		Owner := Map("EraseUnits", 2, "OnlyText", true, "PlainInsertedText", Inserted,
			"EndCharPart", "", "IsPrivate", false, "Trigger", "ab",
			"ReplacementForLog", Inserted, "HType", "star", "Category", "fixture", "Section", "fixture")
		if Raw
			Owner["RawEffect"] := { Ins: Inserted }
		HSE_Buffer := "xxab" . Trailing
		_LSCResetFrom([])
		Effect := _HSE_CommitTerminalOwner(Owner, Trailing)
		AssertTrue(IsObject(Effect), "the actual terminal committer publishes its effect")
		AssertEqual("xx" . Inserted, HSE_Buffer, "posted trailing text is left for the existing replay owner")
		_UnicodeLedgerAssert(WithTrailing ? Trailing : Emoji)
	}
}
Test("synthetic unicode-ledger: primitive output preserves the complete timing key", (*) => _UnicodeLedgerOutput("primitive"))
Test("synthetic unicode-ledger: atomic dispatch preserves the complete timing key", (*) => _UnicodeLedgerOutput("atomic"))
Test("synthetic unicode-ledger: clipboard dispatch preserves the complete timing key", (*) => _UnicodeLedgerOutput("paste"))
Test("synthetic unicode-ledger: atomic output admits a subsequent real timed expansion", (*) => _UnicodeLedgerOutput("followup"))
Test("synthetic unicode-ledger: normal terminal replacement publishes a complete scalar", (*) => _UnicodeLedgerTerminal(false, false))
Test("synthetic unicode-ledger: raw terminal replacement publishes a complete scalar", (*) => _UnicodeLedgerTerminal(true, false))
Test("synthetic unicode-ledger: normal terminal trailing text publishes a complete scalar", (*) => _UnicodeLedgerTerminal(false, true))
Test("synthetic unicode-ledger: raw terminal trailing text publishes a complete scalar", (*) => _UnicodeLedgerTerminal(true, true))

Test("synthetic unicode-ledger: atomic dispatch preserves a supplementary end character",
	_UnicodeLedgerOutput.Bind("atomic-endchar"))
Test("synthetic unicode-ledger: clipboard dispatch preserves a supplementary end character",
	_UnicodeLedgerOutput.Bind("paste-endchar"))

; ================================================
; ======= Native Notepad completion ownership ====
; ================================================

_HNP_Run(Body) {
	global _HSE_TerminalOwner, _LLM_Bridge_Buffer, _PrefixPrivateResidue
	global _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration, _LLM_Bridge_PrefixObserver, _LLM_Live
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _PrefixDeferredGeneration, _PrefixFocusedControlToken, _HSE_TerminalOwnerSerial
	global _PrefixRenderTimer, _PrefixRenderScheduledGeneration, _PrefixRenderQueuedWallMs
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE, _OUTPUT_HOST_METADATA_PROBE
	global _OUTPUT_HOST_TITLE_PROBE, _OUTPUT_HOST_RESOLVE_SERIAL
	AssertFalse(HSE_TerminalTransactionPending(), "the passive fixture cannot adopt an active output")
	AssertEqual(0, _LLM_Bridge_PrefixObserver, "the passive fixture cannot replace a live prefix observer")
	AssertFalse((_PrefixRenderTimer is Map) && !_PrefixRenderTimer.Get("Fired", false),
		"the passive fixture cannot replace a live render timer")
	Saved := { Owner: _HSE_TerminalOwner, Llm: _LLM_Bridge_Buffer,
		LlmActive: _LLM_Bridge_Active, LlmGeneration: _LLM_Bridge_ContentGeneration, Live: _LLM_Live,
		Private: _PrefixPrivateResidue, Content: _PrefixContentGeneration,
		Deferred: _PrefixDeferredGeneration, FocusToken: _PrefixFocusedControlToken,
		OwnerSerial: _HSE_TerminalOwnerSerial, RenderTimer: _PrefixRenderTimer,
		RenderGeneration: _PrefixRenderScheduledGeneration, RenderWall: _PrefixRenderQueuedWallMs,
		Context: _PrefixInputContextGeneration, Cache: _OUTPUT_HOST_CACHE,
		Identity: _OUTPUT_HOST_IDENTITY_PROBE, Metadata: _OUTPUT_HOST_METADATA_PROBE,
		Title: _OUTPUT_HOST_TITLE_PROBE, Serial: _OUTPUT_HOST_RESOLVE_SERIAL }
	try {
		_LLM_Bridge_Active := true
		_LLM_Live := _LLM_Live.Clone()
		_LLM_Live["active"] := false
		_PrefixRenderTimer := 0
		_PrefixRenderScheduledGeneration := -1
		_AHK04_RunIsolated(_HNP_InvokeAndSettle.Bind(Body))
	}
	finally {
		try TimerCancel(_PrefixRenderTimer)
		finally {
			_PrefixRenderTimer := Saved.RenderTimer
			_PrefixRenderScheduledGeneration := Saved.RenderGeneration
			_PrefixRenderQueuedWallMs := Saved.RenderWall
			_PrefixDeferredGeneration := Saved.Deferred
			_PrefixFocusedControlToken := Saved.FocusToken
			_HSE_TerminalOwnerSerial := Saved.OwnerSerial
			_HSE_TerminalOwner := Saved.Owner
			_LLM_Bridge_Buffer := Saved.Llm
			_LLM_Bridge_Active := Saved.LlmActive
			_LLM_Bridge_ContentGeneration := Saved.LlmGeneration
			_LLM_Live := Saved.Live
			_PrefixPrivateResidue := Saved.Private
			_PrefixContentGeneration := Saved.Content
			_PrefixInputContextGeneration := Saved.Context
			_OUTPUT_HOST_CACHE := Saved.Cache
			_OUTPUT_HOST_IDENTITY_PROBE := Saved.Identity
			_OUTPUT_HOST_METADATA_PROBE := Saved.Metadata
			_OUTPUT_HOST_TITLE_PROBE := Saved.Title
			_OUTPUT_HOST_RESOLVE_SERIAL := Saved.Serial
		}
	}
}

_HNP_InvokeAndSettle(Body) {
	global _HSE_TerminalOwner
	try Body.Call()
	finally {
		if (_HSE_TerminalOwner is Map) && _HSE_TerminalOwner["Pending"]
			_HSE_CompleteNotepadOwner(_HSE_TerminalOwner, false, "fixture cleanup")
	}
}

_HNP_Record(State, Text, Opts, Callback) {
	State["Requests"].Push({Text: Text, Opts: Opts, Callback: Callback})
}

/** Records the native caller contract while delivering an inline terminal verdict. */
_HNP_InlineSend(Ok, Text, Opts, Callback) {
	global _AHK04_SendCalls
	_AHK04_SendCalls.Push({Name: "NativeTextSend", Args: [Text, Opts]})
	Finalizer := 0
	if Ok {
		PreviousCritical := Critical("On")
		try Finalizer := Opts["atomic_commit"].Call()
		finally Critical(PreviousCritical)
		if HasMethod(Finalizer, "Call")
			Finalizer.Call()
	}
	Callback.Call(Ok, Ok ? "" : "recorded native refusal")
}

_HNP_Dispatch(State, Buffer := "xxab", EndChar := "") {
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	HSE_Buffer := Buffer
	_PrefixBuffer := Buffer
	_LLM_Bridge_Buffer := Buffer
	OutputHostResolverPrimeForTest("notepad.exe")
	Spec := _AHK04_NormalSpec()
	Effect := 0
	return HSE_DispatchMatch(Spec, EndChar, &Effect, false, _HNP_Record.Bind(State))
}

/** Executes the real commit hook at the future backend's terminal boundary. */
_HNP_Settle(State, Ok := true) {
	Request := State["Requests"][1]
	Finalizer := 0
	if Ok {
		PreviousCritical := Critical("On")
		try Finalizer := Request.Opts["atomic_commit"].Call()
		finally Critical(PreviousCritical)
		if HasMethod(Finalizer, "Call")
			Finalizer.Call()
	}
	Request.Callback.Call(Ok, Ok ? "" : "recorded native refusal")
}

_HNP_PendingThenCommitted() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _LLM_Bridge_Buffer, _PrefixWatcherSuppressed, _HSE_FireLogQueue
		State := Map("Requests", [])
		Owner := _HNP_Dispatch(State)
		AssertTrue(Owner is Map, "native dispatch must return its pending owner")
		AssertTrue(Owner["Pending"], "Begin is not an output verdict")
		AssertEqual(1, State["Requests"].Length, "one immutable request is submitted")
		Request := State["Requests"][1]
		AssertEqual("native", Request.Opts["mode"], "Notepad cannot fall back to keyboard paste")
		AssertEqual("ab", Request.Opts["deleted_text"], "the actual typed suffix is submitted")
		AssertEqual("xxab", HSE_Buffer, "pending output cannot rewrite HSE")
		AssertEqual("xxab", _LLM_Bridge_Buffer, "pending output cannot rewrite LLM")
		AssertEqual(0, _HSE_FireLogQueue.Length, "pending output is not a fire")
		AssertEqual(1, _PrefixWatcherSuppressed, "the pending owner retains suppression")
		_HNP_Settle(State)
		AssertEqual("xxZ", HSE_Buffer, "the actual completion hook commits once")
		AssertEqual("xxZ", _LLM_Bridge_Buffer, "the same effect reaches LLM")
		AssertEqual(1, _HSE_FireLogQueue.Length, "verified completion records one fire")
		AssertEqual(0, _PrefixWatcherSuppressed, "completion releases suppression")
		AssertEqual(0, Keylogger.synth_active, "completion releases its synthetic marker")
		Request.Callback.Call(true, "")
		AssertEqual("xxZ", HSE_Buffer, "duplicate completion cannot commit again")
		AssertEqual(1, _HSE_FireLogQueue.Length, "duplicate completion cannot record another fire")
		AssertEqual(0, _PrefixWatcherSuppressed, "duplicate completion cannot underflow suppression")
	}
}
Test("Notepad pending owner: commit and cleanup occur once after completion (notepad-pending)",
	_HNP_PendingThenCommitted)

_HNP_RefusalDoesNotCommit() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _HSE_FireLogQueue, _PrefixWatcherSuppressed
		State := Map("Requests", [])
		Owner := _HNP_Dispatch(State)
		_HNP_Settle(State, false)
		AssertEqual("xxab", HSE_Buffer, "a pre-effect refusal leaves the typed buffer intact")
		AssertEqual(0, _HSE_FireLogQueue.Length, "a refused request is not a fire")
		AssertFalse(Owner["FinalSucceeded"], "refusal cannot become completed output")
		AssertEqual(0, _PrefixWatcherSuppressed, "refusal releases suppression once")
		AssertEqual(0, Keylogger.synth_active, "refusal releases its synthetic marker")
	}
}
Test("Notepad pending owner: native refusal leaves canonical state unchanged (notepad-pending)",
	_HNP_RefusalDoesNotCommit)

_HNP_SuccessRequiresCommit() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _HSE_FireLogQueue
		State := Map("Requests", [])
		Owner := _HNP_Dispatch(State)
		State["Requests"][1].Callback.Call(true, "")
		AssertFalse(Owner["FinalSucceeded"], "a success scalar cannot replace the commit hook")
		AssertEqual("xxab", HSE_Buffer, "an unauthenticated completion cannot edit a mirror")
		AssertEqual(0, _HSE_FireLogQueue.Length, "an unauthenticated completion cannot report a fire")
	}
}
Test("Notepad pending owner: callback success alone cannot publish a fire (notepad-pending)",
	_HNP_SuccessRequiresCommit)

_HNP_StaleAfterEffectRecovers() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _LLM_Bridge_Buffer, _HSE_FireLogQueue, _PrefixContentGeneration
		State := Map("Requests", [])
		Owner := _HNP_Dispatch(State)
		Request := State["Requests"][1]
		_PrefixContentGeneration += 1
		AssertFalse(Request.Opts["admission"].Call(), "a later input event revokes the original authority")
		Failure := 0
		Finalizer := 0
		PreviousCritical := Critical("On")
		try {
			try Request.Opts["atomic_commit"].Call()
			catch as CommitFailure {
				Failure := CommitFailure
				Finalizer := Request.Opts["commit_failure"].Call(CommitFailure.Message)
			}
		} finally Critical(PreviousCritical)
		AssertEqual("Error", Type(Failure), "a stale post-effect commit must refuse with the named owner error")
		AssertEqual("The Notepad canonical commit lost its original input context.", Failure.Message,
			"the refusal must come from the actual immutable-authority guard")
		if HasMethod(Finalizer, "Call")
			Finalizer.Call()
		Request.Callback.Call(false, "effect unverified")
		AssertEqual("", HSE_Buffer, "uncertain output invalidates HSE knowledge")
		AssertEqual("", _LLM_Bridge_Buffer, "uncertain output invalidates LLM knowledge")
		AssertEqual(0, _HSE_FireLogQueue.Length, "uncertain output never publishes a fire")
		AssertFalse(Owner["FinalSucceeded"], "recovery is not receiving success")
	}
}
Test("Notepad pending owner: stale post-effect state resets mirrors without a fire (notepad-pending)",
	_HNP_StaleAfterEffectRecovers)

_HNP_ExactSuffixAndDelimiter() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, HSE_CONSUMED_DELIMITERS
		SavedConsumedDelimiters := HSE_CONSUMED_DELIMITERS
		try {
			HSE_CONSUMED_DELIMITERS := " "
			State := Map("Requests", [])
			Owner := _HNP_Dispatch(State, "xxAB ", " ")
			AssertTrue(Owner is Map, "the end-character route must own completion")
			Request := State["Requests"][1]
			AssertEqual("AB ", Request.Opts["deleted_text"], "typed case and delimiter survive independently of Spec.Trigger")
			AssertEqual(3, Request.Opts["erase_before"], "the complete typed suffix is erased")
			AssertEqual("Z", Request.Text, "the configured consumed delimiter is not reinserted")
			_HNP_Settle(State)
			AssertEqual("xxZ", HSE_Buffer, "the canonical effect deletes the exact suffix")
		} finally HSE_CONSUMED_DELIMITERS := SavedConsumedDelimiters
	}
}
Test("Notepad pending owner: exact typed case and consumed delimiter are preserved (notepad-pending)",
	_HNP_ExactSuffixAndDelimiter)

_HNP_ThrowingSenderCleansOnce() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _PrefixBuffer, _PrefixWatcherSuppressed
		HSE_Buffer := "xxab"
		_PrefixBuffer := HSE_Buffer
		OutputHostResolverPrimeForTest("notepad.exe")
		Failure := Error("recorded native Begin refusal")
		Thrown := 0
		try HSE_DispatchMatch(_AHK04_NormalSpec(), "", , false, _Throw.Bind(Failure))
		catch as SenderFailure
			Thrown := SenderFailure
		AssertTrue(Thrown == Failure, "the original sender exception is preserved")
		AssertEqual("xxab", HSE_Buffer, "Begin refusal does not commit an effect")
		AssertEqual(0, _PrefixWatcherSuppressed, "throwing Begin releases suppression once")
		AssertEqual(0, Keylogger.synth_active, "throwing Begin releases its synthetic marker once")
	}
	_Throw(Failure, Text, Opts, Callback) {
		throw Failure
	}
}
Test("Notepad pending owner: throwing Begin preserves its error and balances ownership (notepad-pending)",
	_HNP_ThrowingSenderCleansOnce)

_HNP_InitiatingPrefixDoesNotRevoke() {
	_HNP_Run(_Body)
	_Body() {
		global _PrefixBuffer, _PrefixContentGeneration, HSE_Buffer
		State := Map("Requests", [])
		Owner := _HNP_Dispatch(State)
		_PrefixBuffer := "xxa"
		BeforeGeneration := _PrefixContentGeneration
		AssertTrue(_HSE_RetainNotepadPrefixChar(Owner, "b"),
			"the actual pending-owner helper retains the initiating callback")
		AssertEqual(BeforeGeneration, _PrefixContentGeneration,
			"retaining the already-fed trigger cannot change its original authority")
		AssertEqual("xxa", _PrefixBuffer, "presentation waits for its terminal verdict")
		AssertFalse(_HSE_RetainNotepadPrefixChar(Map("Pending", true), "b"),
			"ordinary terminal owners keep their original prefix path")
		_HNP_Settle(State, false)
		AssertEqual("xxab", HSE_Buffer, "pre-effect refusal keeps the typed engine state")
		AssertEqual("xxab", _PrefixBuffer, "pre-effect refusal restores the complete typed preview")
		AssertEqual(BeforeGeneration + 1, _PrefixContentGeneration,
			"refusal publishes exactly one owned preview mutation")
	}
}
Test("Notepad pending owner: initiating prefix bookkeeping preserves immutable admission (notepad-pending)",
	_HNP_InitiatingPrefixDoesNotRevoke)

; ==================================================
; ======= Native raw-callback preparation ==========
; ==================================================

_HNR_Dispatch(State, Callback, Buffer, Trigger, SupportsPreparation := true) {
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	HSE_Buffer := Buffer
	_PrefixBuffer := Buffer
	_LLM_Bridge_Buffer := Buffer
	OutputHostResolverPrimeForTest("notepad.exe")
	_AHK04_SetSendVerdict(true)
	Spec := {Trigger: Trigger, RawCallback: true, Callback: Callback,
		SupportsPreparation: SupportsPreparation, IsPrivate: false}
	Effect := 0
	return HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_Record.Bind(State))
}

_HNR_EllipsisPreparesAndCommits() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _LLM_Bridge_Buffer, _AHK04_SendCalls, _HSE_FireLogQueue
		State := Map("Requests", [])
		_LSCResetFrom(["a", ".", ".", "."])
		_AHK04_SetSendVerdict(true)
		Owner := _HNR_Dispatch(State, _EllipsisRawCallback, "a...", "...")
		AssertTrue(Owner is Map, "the actual ellipsis callback must prepare a pending owner")
		AssertEqual(0, _AHK04_SendCalls.Length, "prepare-only must emit no keyboard burst")
		AssertEqual("a...", HSE_Buffer, "preparation cannot mutate the canonical buffer")
		AssertEqual("...", State["Requests"][1].Opts["deleted_text"], "the three literal dots own deletion")
		AssertEqual("…", State["Requests"][1].Text, "the native request carries the actual prepared insertion")
		_HNP_Settle(State)
		AssertEqual("a…", HSE_Buffer, "the terminal commit applies the prepared raw edit once")
		AssertEqual("a…", _LLM_Bridge_Buffer, "the same exact raw edit reaches the LLM mirror")
		AssertEqual(1, _HSE_FireLogQueue.Length, "verified raw completion records one fire")
		AssertEqual("…", GetLastSentCharacterAt(-1), "completion updates the actual last-character ring")
	}
}
Test("Notepad raw: actual ellipsis prepares without keyboard output and commits once (notepad-raw)",
	_HNR_EllipsisPreparesAndCommits)

_HNR_DeadkeyPreparesAndCommits() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _AHK04_SendCalls
		State := Map("Requests", [])
		_LSCResetFrom([" ", "ê", "x"])
		_AHK04_SetSendVerdict(true)
		Owner := _HNR_Dispatch(State, _Prepare, " êx", "êx")
		AssertTrue(Owner is Map, "the actual deadkey helper must prepare the owned replacement")
		AssertEqual(0, _AHK04_SendCalls.Length, "deadkey preparation cannot send backspaces")
		AssertEqual("êx", State["Requests"][1].Opts["deleted_text"], "the exact deadkey suffix is copied")
		AssertEqual("★", State["Requests"][1].Text, "the mapped symbol remains literal")
		_HNP_Settle(State)
		AssertEqual(" ★", HSE_Buffer, "completion preserves the prefix before the two-scalar raw edit")
	}
	_Prepare(EndChar, PrepareOnly) {
		return ShouldActivateDeadkey("êx", "★", 0, PrepareOnly)
	}
}
Test("Notepad raw: actual deadkey helper prepares its exact suffix without sending (notepad-raw)",
	_HNR_DeadkeyPreparesAndCommits)

_HNR_DeclinedPreparationDoesNotSchedule() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _AHK04_SendCalls, _PrefixWatcherSuppressed
		State := Map("Requests", [])
		_LSCResetFrom(["[", ".", ".", "."])
		AssertFalse(_HNR_Dispatch(State, _EllipsisRawCallback, "[...", "..."),
			"the actual non-letter ellipsis condition must decline")
		AssertEqual(0, State["Requests"].Length, "a declined preparation cannot acquire native work")
		AssertEqual(0, _AHK04_SendCalls.Length, "a declined preparation cannot fall back to keyboard output")
		AssertEqual("[...", HSE_Buffer, "the existing typed text remains authoritative")
		AssertEqual(0, _PrefixWatcherSuppressed, "decline acquires no output suppression")
	}
}
Test("Notepad raw: declined actual ellipsis preparation schedules no output (notepad-raw)",
	_HNR_DeclinedPreparationDoesNotSchedule)

_HNR_UndeclaredCallbackIsNeverInvoked() {
	_HNP_Run(_Body)
	_Body() {
		global _AHK04_SendCalls
		State := Map("Requests", [], "Calls", 0)
		AssertFalse(_HNR_Dispatch(State, _Unsafe.Bind(State), "ab", "ab", false),
			"a callback without a prepare-only contract must refuse")
		AssertEqual(0, State["Calls"], "an undeclared callback is refused before invocation")
		AssertEqual(0, State["Requests"].Length, "refusal cannot publish native work")
		AssertEqual(0, _AHK04_SendCalls.Length, "the callback's own sender must remain unreachable")
	}
	_Unsafe(State, Args*) {
		State["Calls"] += 1
		SendNewResult("{BackSpace 2}{Text}bad", false)
		return {Prepared: true, Ok: true, Bs: 2, Ins: "bad"}
	}
}
Test("Notepad raw: undeclared callbacks are refused before their emitter executes (notepad-raw)",
	_HNR_UndeclaredCallbackIsNeverInvoked)

_HNR_MalformedPreparedPlansRefuse() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _AHK04_SendCalls, _PrefixWatcherSuppressed
		for Plan in [
			{Prepared: true, Ok: "1", Bs: 1, Ins: "Z"},
			{Prepared: "1", Ok: true, Bs: 1, Ins: "Z"},
			{Prepared: true, Ok: true, Bs: 3, Ins: "Z"},
			{Prepared: true, Ok: true, Bs: -1, Ins: "Z"},
			{Prepared: true, Ok: true, Bs: 1, Ins: 0}
		] {
			State := Map("Requests", [])
			AssertFalse(_HNR_Dispatch(State, _Return.Bind(Plan), "ab", "ab"),
				"malformed or out-of-range preparation must refuse before effects")
			AssertEqual(0, State["Requests"].Length, "malformed plans cannot acquire native output")
			AssertEqual("ab", HSE_Buffer, "malformed plans cannot edit canonical text")
			AssertEqual(0, _AHK04_SendCalls.Length, "malformed plans have no keyboard fallback")
			AssertEqual(0, _PrefixWatcherSuppressed, "malformed plans acquire no suppression")
		}
	}
	_Return(Plan, EndChar, PrepareOnly) {
		return Plan
	}
}
Test("Notepad raw: exact Boolean and range validation rejects malformed plans (notepad-raw)",
	_HNR_MalformedPreparedPlansRefuse)


; ==================================================
; ======= Raw preparation registration contract ====
; ==================================================

_HNR_ActualRegistrationTransportsPreparation() {
	global _HotstringRegistrar, HSE_RegistryByGroup, HSE_DisabledGroups
	global HSE_SeqCounter, HSE_RegistryGeneration, HSE_RegistryTransitionDepth
	PreviousCritical := Critical("On")
	SavedRegistrar := _HotstringRegistrar
	SavedGroups := HSE_RegistryByGroup
	SavedDisabled := HSE_DisabledGroups
	SavedSequence := HSE_SeqCounter
	SavedGeneration := HSE_RegistryGeneration
	SavedTransition := HSE_RegistryTransitionDepth
	try {
		_HotstringRegistrar := 0
		; A disabled private group exercises actual metadata transport without
		; inserting a trigger into the host's live matcher or refreshing pixels.
		Group := "notepad-raw-registration-fixture"
		HSE_RegistryByGroup := Map()
		HSE_DisabledGroups := Map(Group, true)
		HSE_RegistryTransitionDepth := SavedTransition + 1
		Callback := _NeverInvoke
		CreateRawCallbackHotstring("*?C", "raw-prepared", Callback,
			Map("Group", Group, "SupportsPreparation", true))
		CreateRawCallbackHotstring("*?C", "raw-default", Callback, Map("Group", Group))
		CreateRawCallbackHotstring("*?C", "raw-disabled", Callback,
			Map("Group", Group, "SupportsPreparation", false))
		Specs := HSE_RegistryByGroup[Group]
		AssertEqual(3, Specs.Length, "the actual registration owner publishes three specs")
		AssertTrue(Specs[1].RawCallback, "registration preserves raw dispatch identity")
		AssertTrue(Specs[1].SupportsPreparation is Integer,
			"the transported capability must retain its Boolean representation")
		AssertEqual(true, Specs[1].SupportsPreparation, "the actual spec carries the explicit capability")
		AssertTrue(Specs[1].Callback == Callback, "the capability belongs to the registered callback")
		AssertFalse(Specs[2].HasOwnProp("SupportsPreparation"), "omitted options preserve the old metadata shape")
		AssertFalse(Specs[3].HasOwnProp("SupportsPreparation"), "explicit false grants no prepare capability")
		BeforeSequence := HSE_SeqCounter
		BeforeGeneration := HSE_RegistryGeneration
		Refused := false
		try CreateRawCallbackHotstring("*?C", "raw-invalid", Callback,
			Map("Group", Group, "SupportsPreparation", "1"))
		catch as RegistrationError {
			if Type(RegistrationError) != "TypeError"
					|| RegistrationError.Message != "Raw callback preparation support must be Boolean."
				throw RegistrationError
			Refused := true
		}
		AssertTrue(Refused, "a string Boolean must fail before registry acquisition")
		AssertEqual(3, Specs.Length, "refusal cannot publish a fourth spec")
		AssertEqual(BeforeSequence, HSE_SeqCounter, "refusal cannot consume insertion identity")
		AssertEqual(BeforeGeneration, HSE_RegistryGeneration, "refusal cannot invalidate existing decisions")
	} finally {
		_HotstringRegistrar := SavedRegistrar
		HSE_RegistryByGroup := SavedGroups
		HSE_DisabledGroups := SavedDisabled
		HSE_SeqCounter := SavedSequence
		HSE_RegistryGeneration := SavedGeneration
		HSE_RegistryTransitionDepth := SavedTransition
		Critical(PreviousCritical)
	}
	_NeverInvoke(Args*) {
		throw Error("Registration must not invoke its raw callback.")
	}
}
Test("Notepad raw registration: actual builder transports only explicit Boolean preparation (notepad-raw-registration)",
	_HNR_ActualRegistrationTransportsPreparation)

/** Keeps the Unicode ledger on the real asynchronous TextSender commit path. */
_UnicodeLedgerNativeOutput(WithEndChar) {
	_HNP_Run(_ULN_Body.Bind(WithEndChar))
}

_ULN_Body(WithEndChar) {
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer, _TEXT_NATIVE_OWNER
	global _TEXT_NATIVE_SERIAL, _LSC_LEN, _HSE_FireLogQueue, _TEXT_CLIPBOARD_QUEUE
	AssertFalse(_TEXT_NATIVE_OWNER, "the ledger fixture cannot adopt another native request")
	SavedSerial := _TEXT_NATIVE_SERIAL
	QueueLength := _TEXT_CLIPBOARD_QUEUE.Length
	Emoji := Chr(0x1F600)
	EndChar := WithEndChar ? Emoji : ""
	Seed := "xxab" . EndChar
	State := { Phase: 1, Scheduled: 0, Requests: [], Callbacks: 0,
		Begins: 0, Decisions: 0, Closes: 0, Owner: 0 }
	State.Port := Map(
		"focus", () => Map("hwnd", 100, "control", 1001, "pid", 77),
		"begin", (Owner) => (State.Owner := Owner, State.Begins += 1, 0),
		"poll", (Token) => Map("phase", State.Phase, "os_error", 0),
		"decide", (Token, Commit) => (State.Decisions += 1, State.Admitted := Commit, 0),
		"close", (Token) => (State.Closes += 1, 0),
		"schedule", (Callback) => (State.Scheduled := Callback))
	try {
		SimulateNotepadActive()
		_LSCResetFrom([])
		Spec := _AHK04_NormalSpec()
		Spec.Replacement := WithEndChar ? "R" : Emoji
		HSE_Buffer := Seed
		_PrefixBuffer := Seed
		_LLM_Bridge_Buffer := Seed
		Pending := HSE_DispatchMatch(Spec, EndChar, , false, _ULN_Send.Bind(State))
		AssertTrue(Pending is Map, "native output returns its pending canonical owner")
		AssertTrue(Pending["Pending"], "queueing does not complete a synthetic output")
		AssertEqual(1, State.Requests.Length, "one literal request owns the output")
		Request := State.Requests[1]
		AssertEqual(WithEndChar ? 3 : 2, Request.Opts["erase_before"],
			"the erasure counts the complete supplementary completion as one scalar")
		AssertEqual("ab" . EndChar, Request.Opts["deleted_text"], "the actual typed UTF-16 suffix is retained")
		AssertEqual(WithEndChar ? 4 : 2, StrLen(Request.Opts["deleted_text"]),
			"the native deletion span includes both surrogate units")
		AssertEqual(WithEndChar ? "R" . Emoji : Emoji, Request.Text,
			"the native literal retains the complete result and unconsumed completion")
		AssertEqual(Seed, HSE_Buffer, "pending output cannot publish the HSE mirror")
		AssertEqual(Seed, _LLM_Bridge_Buffer, "pending output cannot publish the LLM mirror")
		AssertEqual(0, _LSC_LEN, "pending output cannot publish a ring entry")
		AssertEqual(0, _HSE_FireLogQueue.Length, "pending output cannot publish a fire")
		State.Scheduled.Call()
		AssertEqual(1, State.Begins, "the actual TextSender owner begins once")
		State.Phase := 2
		State.Scheduled.Call()
		AssertEqual(1, State.Admitted, "ready admission permits the recorded native effect")
		AssertEqual(Seed, HSE_Buffer, "ready admission is not receiving completion")
		AssertEqual(0, _LSC_LEN, "ready admission cannot publish the timing scalar")
		State.Phase := 4
		State.Scheduled.Call()
		AssertTrue(Pending["FinalSucceeded"], "the actual commit and callback complete the owner")
		AssertEqual("xx" . (WithEndChar ? "R" : "") . Emoji, HSE_Buffer,
			"actual asynchronous settlement commits the emitted supplementary result")
		AssertEqual(HSE_Buffer, _LLM_Bridge_Buffer, "both complete mirrors describe the same effect")
		_UnicodeLedgerAssert(Emoji)
		AssertEqual(1, State.Callbacks, "the real TextSender invokes completion once")
		AssertEqual(1, State.Closes, "the recording native job closes once")
		State.Scheduled.Call()
		AssertEqual(1, State.Callbacks, "duplicate polling cannot republish completion")
		AssertEqual(1, State.Decisions, "duplicate polling cannot authorize another effect")
		AssertEqual(QueueLength, _TEXT_CLIPBOARD_QUEUE.Length, "native output queues no clipboard sender")
	} finally {
		try {
			if State.Owner && _TEXT_NATIVE_OWNER == State.Owner
				_TextSenderFinishNative(State.Owner, 5, 0, "Unicode ledger fixture cleanup")
		} finally _TEXT_NATIVE_SERIAL := SavedSerial
	}
}

_ULN_Send(State, Text, Opts, Callback) {
	global _TEXT_NATIVE_OWNER
	State.Requests.Push({ Text: Text, Opts: Opts })
	Options := Opts.Clone()
	Options["native_port"] := State.Port
	TextSend(Text, Options, _ULN_Complete.Bind(State, Callback))
	State.Owner := _TEXT_NATIVE_OWNER
}

_ULN_Complete(State, Callback, Ok, ErrorMessage := "") {
	State.Callbacks += 1
	Callback.Call(Ok, ErrorMessage)
}

/** Exercises upstream publication authority through the actual deferred native owner. */
_HNPG_PublicationReceipt(Gate) {
	global _PrefixContentGeneration
	Gate["Reads"] += 1
	if Gate.Get("Throws", false)
		throw Error("recorded publication refusal")
	if Gate.Get("MutatesContext", false)
		_PrefixContentGeneration += 1
	return Gate["Verdict"]
}

_HNPG_Dispatch(State, Gate) {
	global HSE_Buffer, _PrefixBuffer, _LLM_Bridge_Buffer
	HSE_Buffer := "xxab"
	_PrefixBuffer := "xxab"
	_LLM_Bridge_Buffer := "xxab"
	OutputHostResolverPrimeForTest("notepad.exe")
	Spec := _AHK04_NormalSpec()
	Spec.PublicationCurrent := _HNPG_PublicationReceipt.Bind(Gate)
	Spec.UserCodeGeneration := 123
	Effect := 0
	Owner := HSE_DispatchMatch(Spec, "", &Effect, false, _HNP_Record.Bind(State))
	AssertTrue(Owner is Map, "native dispatch must retain its actual pending owner")
	AssertTrue(Owner.Has("PublicationCurrent"), "the native owner must retain upstream publication authority")
	AssertTrue(Owner["PublicationCurrent"] == Spec.PublicationCurrent,
		"the native owner must retain the exact supplied publication callback")
	AssertTrue(Owner["UserCodeOwned"], "the native owner must retain user-code ownership")
	AssertEqual(1, State["Requests"].Length, "one native request must reach the actual recording sender")
	return Owner
}

_HNPG_CurrentPublicationCommits() {
	_HNP_Run(_Body)
	_Body() {
		global HSE_Buffer, _LLM_Bridge_Buffer, _HSE_FireLogQueue, _PrefixWatcherSuppressed
		Gate := Map("Verdict", 1, "Reads", 0)
		State := Map("Requests", [])
		Owner := _HNPG_Dispatch(State, Gate)
		AssertTrue(State["Requests"][1].Opts["admission"].Call(),
			"strict current publication must admit the original native request")
		ReadsBefore := Gate["Reads"]
		_HNP_Settle(State)
		AssertTrue(Gate["Reads"] > ReadsBefore, "the commit must consult publication again")
		AssertEqual("xxZ", HSE_Buffer, "authorized completion must commit the actual HSE effect")
		AssertEqual("xxZ", _LLM_Bridge_Buffer, "authorized completion must commit the paired mirror")
		AssertTrue(Owner["FinalSucceeded"], "authorized completion must finish successfully")
		AssertEqual(1, _HSE_FireLogQueue.Length, "authorized completion must publish exactly one fire")
		AssertEqual(0, _PrefixWatcherSuppressed, "authorized completion must release suppression")
	}
}
Test("Notepad publication: current upstream receipt commits once (notepad-publication)",
	_HNPG_CurrentPublicationCommits)

_HNPG_RefusedPublicationBody(Mode) {
	global HSE_Buffer, _LLM_Bridge_Buffer, _HSE_FireLogQueue, _PrefixWatcherSuppressed
	Gate := Map("Verdict", 1, "Reads", 0)
	State := Map("Requests", [])
	Owner := _HNPG_Dispatch(State, Gate)
	Request := State["Requests"][1]
	AssertTrue(Request.Opts["admission"].Call(), "the request starts with genuine current publication")
	if Mode == "revoked"
		Gate["Verdict"] := 0
	else if Mode == "malformed"
		Gate["Verdict"] := "1"
	else if Mode == "throwing"
		Gate["Throws"] := true
	else if Mode == "context"
		Gate["MutatesContext"] := true
	else
		throw ValueError("The publication fixture mode is unknown.")
	AssertFalse(Request.Opts["admission"].Call(), "changed publication authority must refuse admission")
	Failure := 0
	PreviousCritical := Critical("On")
	try {
		try Request.Opts["atomic_commit"].Call()
		catch as CommitFailure
			Failure := CommitFailure
	} finally Critical(PreviousCritical)
	AssertEqual("Error", Type(Failure), "the actual canonical commit must refuse the stale receipt")
	ExpectedMessage := Mode == "context"
		? "The Notepad canonical commit lost its original input context."
		: "The Notepad canonical commit lost its publication authority."
	AssertEqual(ExpectedMessage, Failure.Message, "the exact authority guard must cause the refusal")
	AssertEqual("xxab", HSE_Buffer, "refused publication must not edit HSE")
	AssertEqual("xxab", _LLM_Bridge_Buffer, "refused publication must not edit the paired mirror")
	AssertFalse(Owner["Committed"], "refused publication must not claim a canonical commit")
	AssertEqual(0, _HSE_FireLogQueue.Length, "refused publication must not publish a fire")
	Request.Callback.Call(false, "recorded publication refusal")
	AssertFalse(Owner["FinalSucceeded"], "authority refusal cannot report successful output")
	AssertEqual(0, _PrefixWatcherSuppressed, "refusal completion must release owned suppression")
	AssertEqual(0, Keylogger.synth_active, "refusal completion must release its synthetic marker")
	Request.Callback.Call(false, "duplicate recorded refusal")
	AssertEqual(0, _PrefixWatcherSuppressed, "duplicate completion cannot release ownership twice")
}

_HNPG_RevokedPublicationRefuses() {
	_HNP_Run(_HNPG_RefusedPublicationBody.Bind("revoked"))
}
Test("Notepad publication: revoked receipt refuses admission and commit (notepad-publication)",
	_HNPG_RevokedPublicationRefuses)

_HNPG_MalformedPublicationRefuses() {
	_HNP_Run(_HNPG_RefusedPublicationBody.Bind("malformed"))
}
Test("Notepad publication: String receipt cannot impersonate Integer1 (notepad-publication)",
	_HNPG_MalformedPublicationRefuses)

_HNPG_ThrowingPublicationRefuses() {
	_HNP_Run(_HNPG_RefusedPublicationBody.Bind("throwing"))
}
Test("Notepad publication: callback refusal cannot reach canonical mutation (notepad-publication)",
	_HNPG_ThrowingPublicationRefuses)

_HNPG_ContextMutationRefuses() {
	_HNP_Run(_HNPG_RefusedPublicationBody.Bind("context"))
}
Test("Notepad publication: callback context mutation is checked afterward (notepad-publication)",
	_HNPG_ContextMutationRefuses)
