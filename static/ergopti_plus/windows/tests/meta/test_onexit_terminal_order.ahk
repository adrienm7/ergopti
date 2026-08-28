; tests/meta/test_onexit_terminal_order.ahk

; ==============================================================================
; MODULE: Refusal-safe OnExit ordering
; DESCRIPTION:
; Structural guard that a refused shutdown releases OS button state without
; destroying live gesture hooks, while an accepted shutdown unhooks only after
; the last refusal gate and leaves the logger as the final callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_OTO_Read(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(Root . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_OTO_RefusalKeepsGestureHookLive() {
	GestureInit := _OTO_Read("modules/gestures/init.ahk")
	ShutdownBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ShutdownBody != "", "Ergopti_OnShutdown must remain source-visible")
	Assert(InStr(GestureInit, "OnExit(_GestureUnhook") == 0,
		"a sibling OnExit callback must not unhook before the main refusal gates")
	ClaimPos := InStr(ShutdownBody, "ReloadTerminalHandoffClaim(reason)", true)
	TapHoldPos := InStr(ShutdownBody, "TapHoldShutdownReleaseGate()", true)
	FullSavePos := InStr(ShutdownBody, "_ConfigFullSaveSettleTerminal(", true)
	BeginPos := InStr(ShutdownBody, "KL_BeginShutdown()", true)
	FlushReadyPos := InStr(ShutdownBody, "KL_FlushShutdownReady()", true)
	DrainPos := InStr(ShutdownBody,
		"HotstringPrefixWatcherPrepareShutdown()", true)
	LeftPos := InStr(ShutdownBody, "GestureReleaseLeftClick()", true)
	RightPos := InStr(ShutdownBody, "GestureReleaseRightClick()", true)
	Assert(LeftPos > 0 && RightPos > LeftPos && ClaimPos > RightPos,
		"both held buttons must release before even terminal ownership can refuse")
	Assert(TapHoldPos > ClaimPos && FullSavePos > TapHoldPos
		&& BeginPos > FullSavePos && FlushReadyPos > BeginPos
		&& DrainPos > FlushReadyPos,
		"accepted saves must settle before the reversible terminal fire drain")
	FlushFailurePos := InStr(ShutdownBody, "if !KeyloggerFlushReady", true)
	FlushFailureTail := SubStr(ShutdownBody, FlushFailurePos,
		DrainPos - FlushFailurePos)
	Assert(FlushFailurePos > FlushReadyPos
		&& InStr(FlushFailureTail, "KL_CancelShutdown()", true) > 0
		&& InStr(FlushFailureTail, "return 1", true) > 0,
		"an active detached flush must refuse OnExit and withdraw the reversible lease")
	CommitPos := InStr(ShutdownBody, "ReloadTerminalHandoffCommit(", true)
	LoggerReadyPos := InStr(ShutdownBody, "LoggerPrepareShutdown()", true)
	FinalExitPos := InStr(ShutdownBody, "_Updater_SignalFinalExitForIntent()", true)
	TransferPos := InStr(ShutdownBody,
		"_Updater_TransferExitIntentAfterShutdownGates()", true)
	RecoveryPos := InStr(ShutdownBody,
		"_Updater_CompleteRecoveryHandoffOnExit()", true)
	Assert(LoggerReadyPos > DrainPos && CommitPos > LoggerReadyPos
		&& FinalExitPos > CommitPos
		&& TransferPos > FinalExitPos && RecoveryPos > TransferPos,
		"durability and authority gates must run while producers remain live")
	FirstIrreversiblePos := 0
	for CallName in ['GestureScreenshotCancelAll("shutdown")',
		"HotstringPrefixWatcherStop()", "HotstringPrefixWatcherOnShutdown()",
		"KL_Stop()", 'UIASW_Stop("canceled")', "HookDispatcher.Stop()",
		"KLWV_CloseAll()", "OllamaWV_Close()",
		"_Updater_AbortStagingOnExit()"] {
		CallPos := InStr(ShutdownBody, CallName, true)
		Assert(CallPos > RecoveryPos,
			CallName . " must follow every refusal-capable terminal gate")
		if !FirstIrreversiblePos or CallPos < FirstIrreversiblePos
			FirstIrreversiblePos := CallPos
	}
	IrreversibleTail := SubStr(ShutdownBody, FirstIrreversiblePos)
	Assert(!RegExMatch(IrreversibleTail, "m)^\s*return\s+1\b"),
		"no refusal may strand the driver after the first irreversible teardown")
	ReversibleSegment := SubStr(ShutdownBody, BeginPos,
		FirstIrreversiblePos - BeginPos)
	RefusalCount := 0
	CancelCount := 0
	RegExReplace(ReversibleSegment, "m)^\s*return\s+1\b", "", &RefusalCount)
	RegExReplace(ReversibleSegment, "KL_CancelShutdown\(\)", "", &CancelCount)
	Assert(RefusalCount == CancelCount && RefusalCount > 0,
		"every refusal after the reversible keylogger lease must withdraw it")
	FinishPos := InStr(ShutdownBody, "ReloadTerminalHandoffFinish(", true)
	Assert(FinishPos > FirstIrreversiblePos
		&& InStr(ShutdownBody, "TerminalHandoff, _GestureUnhook", true,
			FinishPos) > FinishPos,
		"Finish must report success only after irreversible teardown")
	Finish := _DriverFuncBody("_ReloadTerminalHandoffFinishNonCritical")
	Assert(Finish != "",
		"the non-Critical Finish implementation must remain source-visible")
	ValidatePos := InStr(Finish, 'Record["state"] != "committed"', true)
	TeardownPos := InStr(Finish, "BeforeSuccessFn.Call()", true)
	SuccessPos := InStr(Finish, "SuccessFn.Call()", true)
	Assert(ValidatePos > 0 && TeardownPos > ValidatePos
		&& SuccessPos > TeardownPos,
		"Finish must validate first, then tear down, then report UI success")
}
Test("OnExit: refusal keeps gesture hooks live until terminal acceptance "
	. "(onexit-refusal-safe-order)", _OTO_RefusalKeepsGestureHookLive)

_OTO_MainRunsBeforeFinalLoggerFlush() {
	Main := _OTO_Read("ErgoptiPlus.ahk")
	Logger := _OTO_Read("infra/logger.ahk")
	Assert(InStr(Main, "OnExit(Ergopti_OnShutdown, -1)", true) > 0,
		"the refusal-capable lifecycle callback must be prepended")
	Assert(InStr(Logger, "OnExit(_LoggerOnExitFlush)", true) > 0,
		"the logger must remain a later callback that flushes terminal logs")
}
Test("OnExit: lifecycle precedes the final logger flush "
	. "(onexit-logger-last)", _OTO_MainRunsBeforeFinalLoggerFlush)
