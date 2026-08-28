; tests/unit/test_terminal_hotstring_transaction_owner.ahk

; ==============================================================================
; MODULE: Terminal Hotstring Transaction Owner Tests
; DESCRIPTION:
; The native capture owns schedule, paced output, canonical commit and replay.
; Every failure path balances synthetic/suppression ownership before replay.
; ==============================================================================

#Requires AutoHotkey v2.0

global _THTO_Runner := 0
global _THTO_Payloads := []
global _THTO_SendLevels := []
global _THTO_SendVerdict := true
global _THTO_Identity := Map("Hwnd", 701, "Pid", 7001)
global _THTO_NativeState := 0

_THTO_IdentityProbe() {
	global _THTO_Identity
	return _THTO_Identity.Clone()
}

_THTO_MetadataProbe(Hwnd, Pid) {
	return Map("Exe", "WindowsTerminal.exe", "Class", "fixture", "Title", "Terminal")
}

_THTO_Schedule(Runner, DelayMs) {
	global _THTO_Runner
	_THTO_Runner := Runner
	return true
}

_THTO_RejectSchedule(Runner, DelayMs) {
	return false
}

_THTO_ThrowSchedule(Runner, DelayMs) {
	throw Error("injected scheduler failure")
}

_THTO_InlineSchedule(Runner, DelayMs) {
	global _HSE_TerminalOwner, _THTO_NativeState
	_THTO_NativeState["InlineSawOwner"] := _HSE_TerminalOwner is Map
	Runner.Call()
	return true
}

_THTO_InlineThenFalseSchedule(Runner, DelayMs) {
	Runner.Call()
	return false
}

_THTO_InlineThenThrowSchedule(Runner, DelayMs) {
	Runner.Call()
	throw Error("injected post-run scheduler failure")
}

_THTO_InlineTwiceSchedule(Runner, DelayMs) {
	Runner.Call()
	Runner.Call()
	return true
}

_THTO_Emit(Payload) {
	global _THTO_Payloads, _THTO_SendLevels, _THTO_SendVerdict
	_THTO_Payloads.Push(Payload)
	_THTO_SendLevels.Push(A_SendLevel)
	return _THTO_SendVerdict
}

_THTO_NoOp(*) {
	return true
}

_THTO_NewNativeState() {
	State := Map(
		"BeginMode", "accept", "CommitModes", [], "AbortModes", [],
		"BeginCalls", [], "CommitCalls", [], "AbortCalls", [],
		"Capturing", false, "InlineSawOwner", false, "OnRelease", 0,
		"ReleaseSnapshots", [])
	State["Port"] := Map(
		"begin_terminal", _THTO_PortBegin.Bind(State),
		"commit_terminal", _THTO_PortRelease.Bind(State, true),
		"abort_terminal", _THTO_PortRelease.Bind(State, false),
		"get_terminal", _THTO_PortGet.Bind(State))
	return State
}

_THTO_PortBegin(State, Token) {
	global _HSE_TerminalOwner
	State["BeginCalls"].Push(Token)
	if State["BeginMode"] == "throw"
		throw Error("injected capture admission failure")
	if State["BeginMode"] != "accept"
		return 0
	State["Capturing"] := true
	State["BeginSawOwner"] := _HSE_TerminalOwner is Map
	return 1
}

_THTO_PortRelease(State, Committed, Token) {
	global HSE_Buffer, _HSE_TerminalOwner, _PrefixWatcherSuppressed
	Calls := Committed ? State["CommitCalls"] : State["AbortCalls"]
	Calls.Push(Token)
	Modes := Committed ? State["CommitModes"] : State["AbortModes"]
	Mode := Modes.Length ? Modes.RemoveAt(1) : "accept"
	State["ReleaseSnapshots"].Push(Map(
		"committed", Committed, "buffer", HSE_Buffer,
		"owner_cleared", !(_HSE_TerminalOwner is Map),
		"prefix_depth", _PrefixWatcherSuppressed,
		"synthetic_depth", Keylogger.synth_active))
	OnRelease := State["OnRelease"]
	if HasMethod(OnRelease, "Call")
		OnRelease.Call()
	if Mode == "throw"
		throw Error("injected replay failure")
	if Mode != "accept"
		return 0
	State["Capturing"] := false
	return 1
}

_THTO_PortGet(State, Token) {
	return Map("token", Token, "phase", State["Capturing"] ? 1 : 0,
		"queued", 0, "replayed", 0, "last_os_error", 0,
		"release_kind", 0)
}

_THTO_MakeOwner(CommitFn := 0) {
	global HSE_Buffer, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global _THTO_Identity, _THTO_NativeState
	Owner := Map(
		"Id", 1, "Pending", true, "Backspaces", 7,
		"PlainInsertedText", "XGBoost", "SendPayload", "{Text}XGBoost",
		"EndCharPart", "", "OnlyText", true, "DelayMs", 20,
		"EmitFn", _THTO_Emit, "DelayFn", _THTO_NoOp,
		"BufferSnapshot", HSE_Buffer,
		"Hwnd", _THTO_Identity["Hwnd"], "Pid", _THTO_Identity["Pid"],
		"RegistryGeneration", HSE_RegistryGeneration,
		"DecisionGeneration", HSE_RuntimeDecisionGeneration,
		"InputGeneration", _PrefixInputContextGeneration,
		"LifecycleGeneration", _PrefixDeferredGeneration,
		"Trigger", "xgboost", "ReplacementForLog", "XGBoost",
		"HType", "star", "Category", "fixture", "Section", "fixture",
		"IsPrivate", false,
		"SyntheticOwner", KL_MarkSynthetic("hotstring"),
		"Port", _THTO_NativeState["Port"])
	if HasMethod(CommitFn, "Call")
		Owner["CommitFn"] := CommitFn
	return Owner
}

_THTO_Reset() {
	global HSE_Buffer, _PrefixBuffer, _HSE_TerminalOwner
	global _HSE_TerminalReplayPending, _HSE_TerminalReplaying
	global _THTO_Runner, _THTO_Payloads, _THTO_SendLevels
	global _THTO_SendVerdict, _THTO_Identity
	global _THTO_NativeState, _HSE_FireLogQueue, _HSE_FireLogScheduled
	global _PrefixWatcherSuppressed, _LLM_NavEventOwnerStarted
	global _LLM_NavEventOwnerQuarantined, _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStartRollbackPending, _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerStopPending, _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerLifecycleQuiesced, _LLM_NavEventOwnerPort
	HSE_Buffer := "xgboost"
	_PrefixBuffer := "xgboost"
	_HSE_TerminalOwner := 0
	_HSE_TerminalReplayPending := 0
	_HSE_TerminalReplaying := false
	_THTO_Runner := 0
	_THTO_Payloads := []
	_THTO_SendLevels := []
	_THTO_SendVerdict := true
	_THTO_Identity := Map("Hwnd", 701, "Pid", 7001)
	_THTO_NativeState := _THTO_NewNativeState()
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	_PrefixWatcherSuppressed := 1
	Keylogger.synth_active := 0
	Keylogger.synth_type := "none"
	Keylogger.synth_owners := []
	Keylogger.synth_private := false
	_LLM_NavEventOwnerStarted := true
	_LLM_NavEventOwnerQuarantined := false
	_LLM_NavEventOwnerStarting := false
	_LLM_NavEventOwnerStartRollbackPending := false
	_LLM_NavEventOwnerStopping := false
	_LLM_NavEventOwnerStopPending := false
	_LLM_NavEventOwnerPendingStopRecovery := false
	_LLM_NavEventOwnerLifecycleQuiesced := false
	_LLM_NavEventOwnerPort := _THTO_NativeState["Port"]
	OutputHostResolverConfigure(_THTO_IdentityProbe, _THTO_MetadataProbe)
}

_THTO_CommitThrows(Owner, TrailingText) {
	throw Error("injected canonical commit failure")
}

_THTO_AppendPostedChar(Owner, Char) {
	global HSE_Buffer, _PrefixBuffer
	HSE_Buffer .= Char
	_PrefixBuffer .= Char
	Owner["TrailingText"] .= Char
	Owner["TrailingChars"].Push(Char)
}

_THTO_ReplayVisibleChar(State, Char) {
	global HSE_Buffer, _PrefixBuffer
	State["VisibleReplayCalls"] := State.Get("VisibleReplayCalls", 0) + 1
	State["VisibleReplayOrder"] := State.Get("VisibleReplayOrder", "") . Char
	if !State.Has("CanonicalBeforeVisibleReplay")
		State["CanonicalBeforeVisibleReplay"] := HSE_Buffer
	HSE_Buffer .= Char
	_PrefixBuffer .= Char
	if Char == "q"
		State["SecondMatches"] := State.Get("SecondMatches", 0) + 1
	return true
}

_THTO_ScheduleEmitCommitReleaseOrder() {
	global HSE_Buffer, _PrefixBuffer, _THTO_Runner, _THTO_Payloads
	global _THTO_NativeState, _THTO_SendLevels, _HSE_FireLogQueue
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	Owner["ReplayVisibleFn"] := _THTO_ReplayVisibleChar.Bind(
		_THTO_NativeState)
	Result := _HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule)
	AssertTrue(Result is Map)
	AssertTrue(_THTO_NativeState["BeginSawOwner"])
	; The native hook event for q may already have passed immediately before
	; Begin acquired capture, while its deferred OnChar callback is still queued
	; behind the completing trigger callback. Model that exact boundary: q is
	; visible and canonical before the delayed runner, while every later physical
	; edge belongs to native capture.
	_THTO_AppendPostedChar(Owner, "q")
	PreviousSendLevel := A_SendLevel
	try {
		SendLevel(7)
		AssertTrue(_THTO_Runner.Call())
		AssertEqual(7, A_SendLevel,
			"the terminal transaction must restore its caller's send level")
	} finally SendLevel(PreviousSendLevel)
	AssertEqual("{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{BackSpace}{Text}XGBoostq",
		_THTO_Payloads[1])
	AssertEqual(0, _THTO_SendLevels[1],
		"terminal output must cross native capture below the prefix InputHook level")
	AssertEqual("XGBoostq", HSE_Buffer)
	AssertEqual("XGBoost", _THTO_NativeState["CanonicalBeforeVisibleReplay"])
	AssertEqual("q", _THTO_NativeState["VisibleReplayOrder"])
	AssertEqual(1, _THTO_NativeState["SecondMatches"])
	AssertEqual(1, _HSE_FireLogQueue.Length)
	Snapshot := _THTO_NativeState["ReleaseSnapshots"][1]
	AssertTrue(Snapshot["committed"])
	AssertEqual("XGBoost", Snapshot["buffer"])
	AssertTrue(Snapshot["owner_cleared"])
	AssertEqual(0, Snapshot["prefix_depth"])
	AssertEqual(0, Snapshot["synthetic_depth"])
}
Test("terminal transaction: schedule emit commit and replay are one owner (ahk-001)",
	_THTO_ScheduleEmitCommitReleaseOrder)

_THTO_FailuresAbortWithoutLeakingOwnership() {
	global HSE_Buffer, _THTO_Runner, _THTO_SendVerdict
	global _THTO_NativeState, _HSE_TerminalOwner, _PrefixWatcherSuppressed
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	_THTO_SendVerdict := false
	AssertFalse(_THTO_Runner.Call())
	AssertEqual("xgboost", HSE_Buffer)
	AssertEqual(1, _THTO_NativeState["AbortCalls"].Length)
	AssertFalse(_HSE_TerminalOwner is Map)
	AssertEqual(0, _THTO_NativeState["ReleaseSnapshots"][1]["prefix_depth"])
	for Scheduler in [_THTO_RejectSchedule, _THTO_ThrowSchedule] {
		_THTO_Reset()
		Owner := _THTO_MakeOwner()
		Result := true
		try Result := _HSE_BeginOwnedTerminalTransaction(Owner, Scheduler)
		catch
			Result := false
		AssertFalse(Result)
		AssertEqual(1, _THTO_NativeState["AbortCalls"].Length)
		AssertFalse(_HSE_TerminalOwner is Map)
		AssertEqual(0, _PrefixWatcherSuppressed)
		AssertEqual(0, Keylogger.synth_active)
	}
}
Test("terminal transaction: sender and scheduler failures abort exactly once (ahk2-01)",
	_THTO_FailuresAbortWithoutLeakingOwnership)

_THTO_CommitFailureCannotWedgeOwner() {
	global _THTO_Runner, _THTO_NativeState, _HSE_TerminalOwner
	global _PrefixWatcherSuppressed
	_THTO_Reset()
	Owner := _THTO_MakeOwner(_THTO_CommitThrows)
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	AssertFalse(_THTO_Runner.Call())
	AssertFalse(_HSE_TerminalOwner is Map)
	AssertEqual(0, _PrefixWatcherSuppressed)
	AssertEqual(0, Keylogger.synth_active)
	AssertEqual(1, _THTO_NativeState["AbortCalls"].Length)
}
Test("terminal transaction: fallible canonical commit cannot wedge owner (ahk2-02)",
	_THTO_CommitFailureCannotWedgeOwner)

_THTO_ReplayFailureRetainsExactRetry() {
	global HSE_Buffer, _THTO_Runner, _THTO_NativeState
	global _HSE_TerminalReplayPending
	_THTO_Reset()
	_THTO_NativeState["CommitModes"] := ["refuse", "accept"]
	Owner := _THTO_MakeOwner()
	Owner["ReplayVisibleFn"] := _THTO_ReplayVisibleChar.Bind(
		_THTO_NativeState)
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	_THTO_AppendPostedChar(Owner, "q")
	AssertTrue(_THTO_Runner.Call())
	AssertTrue(_HSE_TerminalReplayPending is Map)
	AssertEqual(1, _THTO_NativeState["CommitCalls"].Length)
	AssertEqual("XGBoost", HSE_Buffer,
		"visible suffix replay must wait for the native release receipt")
	AssertFalse(_THTO_NativeState.Has("VisibleReplayCalls"))
	; A partially accepted SendInput prefix has reached the terminal, but its
	; deferred OnChar callback must remain behind the older pre-admission suffix.
	AssertTrue(_HSE_RetainTerminalReplayChar("r"))
	AssertEqual("XGBoost", HSE_Buffer)
	AssertTrue(_HSE_RetryTerminalReplay())
	AssertFalse(_HSE_TerminalReplayPending is Map)
	AssertEqual(2, _THTO_NativeState["CommitCalls"].Length)
	AssertEqual(2, _THTO_NativeState["VisibleReplayCalls"])
	AssertEqual("qr", _THTO_NativeState["VisibleReplayOrder"])
	AssertEqual("XGBoostqr", HSE_Buffer)
}
Test("terminal transaction: partial native replay retains one exact retry (ahk-001)",
	_THTO_ReplayFailureRetainsExactRetry)

_THTO_InlineSchedulerSeesPublishedOwner() {
	global _THTO_NativeState
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	Result := _HSE_BeginOwnedTerminalTransaction(Owner, _THTO_InlineSchedule)
	AssertTrue(Result is Map)
	AssertTrue(Result["FinalSucceeded"])
	AssertTrue(_THTO_NativeState["InlineSawOwner"])
}
Test("terminal transaction: inline scheduler sees owner before callback (ahk2-01)",
	_THTO_InlineSchedulerSeesPublishedOwner)

_THTO_InlineSchedulerTerminalVerdictIsIdempotent() {
	global _THTO_NativeState
	for Scheduler in [
		_THTO_InlineThenFalseSchedule,
		_THTO_InlineThenThrowSchedule,
		_THTO_InlineTwiceSchedule
	] {
		_THTO_Reset()
		Owner := _THTO_MakeOwner()
		Result := _HSE_BeginOwnedTerminalTransaction(Owner, Scheduler)
		AssertTrue(Result is Map)
		AssertTrue(Result["FinalSucceeded"])
		AssertEqual(1, _THTO_NativeState["CommitCalls"].Length,
			"an inline runner can commit its native capture only once")
		AssertEqual(0, _THTO_NativeState["AbortCalls"].Length,
			"a scheduler verdict after inline completion cannot abort the commit")
		AssertEqual(0, _PrefixWatcherSuppressed)
		AssertEqual(0, Keylogger.synth_active)
	}
}
Test("terminal transaction: inline false throw and duplicate callbacks stay terminal (ahk2-02)",
	_THTO_InlineSchedulerTerminalVerdictIsIdempotent)

_THTO_EachOwnershipGenerationAbortsBeforeOutput() {
	global HSE_RegistryGeneration, _PrefixDeferredGeneration
	global _PrefixInputContextGeneration, _THTO_Runner, _THTO_Payloads
	global _THTO_Identity
	Mutations := [
		(*) => (_THTO_Identity := Map("Hwnd", 702, "Pid", 7002)),
		(*) => (_PrefixDeferredGeneration += 1),
		(*) => (HSE_RegistryGeneration += 1),
		(*) => (_PrefixInputContextGeneration += 1)
	]
	for Mutate in Mutations {
		_THTO_Reset()
		Owner := _THTO_MakeOwner()
		AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
		Mutate.Call()
		AssertFalse(_THTO_Runner.Call())
		AssertEqual(0, _THTO_Payloads.Length)
		AssertFalse(_HSE_TerminalOwner is Map,
			"a stale generation must retire the exact AHK owner")
		AssertEqual(1, _THTO_NativeState["AbortCalls"].Length,
			"a stale generation must abort native capture exactly once")
		AssertEqual(0, _PrefixWatcherSuppressed,
			"a stale generation must balance prefix suppression before replay")
		AssertEqual(0, Keylogger.synth_active,
			"a stale generation must balance synthetic ownership before replay")
	}
}
Test("terminal transaction: every ownership generation is revalidated",
	_THTO_EachOwnershipGenerationAbortsBeforeOutput)

_THTO_ReplayedSecondMatchRunsExactlyOnce() {
	global HSE_Buffer, _THTO_Runner, _THTO_NativeState
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	Owner["ReplayVisibleFn"] := _THTO_ReplayVisibleChar.Bind(
		_THTO_NativeState)
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	_THTO_AppendPostedChar(Owner, "q")
	_THTO_AppendPostedChar(Owner, "z")
	AssertTrue(_THTO_Runner.Call())
	AssertEqual("qz", _THTO_NativeState["VisibleReplayOrder"])
	AssertEqual(2, _THTO_NativeState["VisibleReplayCalls"])
	AssertEqual(1, _THTO_NativeState["SecondMatches"])
	AssertEqual("XGBoostqz", HSE_Buffer)
}
Test("terminal transaction: posted suffix re-enters matching in order exactly once (ahk-001)",
	_THTO_ReplayedSecondMatchRunsExactlyOnce)

_THTO_PostedCallbackChunksKeepExactBoundaries() {
	global _THTO_Runner, _THTO_NativeState
	_THTO_Reset()
	Owner := _THTO_MakeOwner()
	Owner["ReplayVisibleFn"] := _THTO_ReplayVisibleChar.Bind(
		_THTO_NativeState)
	AssertTrue(_HSE_BeginOwnedTerminalTransaction(Owner, _THTO_Schedule) is Map)
	_THTO_AppendPostedChar(Owner, "e" . Chr(0x301))
	AssertTrue(_THTO_Runner.Call())
	AssertEqual(1, _THTO_NativeState["VisibleReplayCalls"],
		"one InputHook callback containing two code points must stay one callback")
	AssertEqual("e" . Chr(0x301), _THTO_NativeState["VisibleReplayOrder"])
}
Test("terminal transaction: posted callback boundaries survive canonical replay (ahk-001)",
	_THTO_PostedCallbackChunksKeepExactBoundaries)

_THTO_RawCallbackPreparesWithoutDirectSend() {
	global HSE_Buffer, _PrefixBuffer, _THTO_Runner, _THTO_Payloads
	global _THTO_NativeState
	_THTO_Reset()
	HSE_Buffer := "a..."
	_PrefixBuffer := "a..."
	DirectCalls := 0
	Raw := (EndChar, PrepareOnly := false) => PrepareOnly
		? { Prepared: true, Ok: true, Bs: 3, Ins: "…" }
		: (++DirectCalls)
	Spec := { RawCallback: true, Callback: Raw, Trigger: "...",
		Category: "fixture", Section: "fixture", IsPrivate: false }
	Host := Map("Valid", true, "Hwnd", 701, "Pid", 7001,
		"Exe", "WindowsTerminal.exe", "Title", "Terminal")
	Result := _HSE_DispatchTerminalRawCallback(
		Spec, "", Host, _THTO_Schedule, _THTO_Emit)
	AssertTrue(Result is Map)
	Result["ReplayVisibleFn"] := _THTO_ReplayVisibleChar.Bind(
		_THTO_NativeState)
	AssertEqual(0, DirectCalls)
	; Same queued-before-admission seam as the normal replacement path.
	_THTO_AppendPostedChar(Result, "q")
	AssertTrue(_THTO_Runner.Call())
	AssertEqual("{BackSpace}{BackSpace}{BackSpace}{BackSpace}{Text}…{Text}q", _THTO_Payloads[1])
	AssertEqual("a…q", HSE_Buffer)
}
Test("terminal raw callbacks use the same paced owner (ahk2-07)",
	_THTO_RawCallbackPreparesWithoutDirectSend)

OutputHostResolverConfigure()
