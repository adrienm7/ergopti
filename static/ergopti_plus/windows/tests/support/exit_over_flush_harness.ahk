; tests/support/exit_over_flush_harness.ahk

; ==============================================================================
; MODULE: Exit Over A Flush Harness
; DESCRIPTION:
; Runs the extracted Ergopti_OnShutdown under a real OnExit and a real ExitApp, so
; a veto and its retry behave as they do in the driver. Every gate before the
; scenario's refusal is a double that accepts. The receipt is written by a later
; OnExit callback, or by the main thread when the exit stayed refused.
; ==============================================================================

_EOF_Count(Name) {
	global _EOF_State
	_EOF_State[Name] := _EOF_State.Get(Name, 0) + 1
	return true
}





; ==================================
; ==================================
; ======= 1/ Accepting gates =======
; ==================================
; ==================================

LoggerError(Module, Template, Args*) {
	global _EOF_State
	_EOF_Count("errors")
	_EOF_State["last_error"] := Template
	return true
}
LoggerInfo(Module, Template, Args*) {
	global _EOF_State
	_EOF_State["infos"] := _EOF_State.Get("infos", "") . Format(Template, Args*) . "|"
	return true
}
LoggerWarn(*) {
	return true
}
NotifyQuitRefused(*) {
	return _EOF_Count("notices")
}
GestureReleaseLeftClick(*) {
	return 1
}
GestureReleaseRightClick(*) {
	return 1
}
LLM_NavEventOwner_PrepareShutdown(*) {
	return true
}
ReloadTerminalHandoffClaim(*) {
	return false
}
ReloadTerminalHandoffPending(*) {
	return false
}
ReloadTerminalHandoffRefuseForShutdown(*) {
	return false
}
ConfigTransitionRetainedBarrier(*) {
	return false
}
ConfigWriteAcquireLifecycleBundle(*) {
	return Map("fixture", true)
}
_ConfigWriteTerminalRelease(*) {
	return true
}
TapHoldShutdownReleaseGate(*) {
	return true
}
LayoutRegistry_PrepareShutdown(*) {
	return true
}
_ConfigFullSaveSettleTerminal(*) {
	return 1
}
_Updater_RecoveryMayEnterTerminalShutdown(*) {
	return true
}
KL_BeginShutdown(*) {
	return true
}
KL_CancelShutdown(*) {
	return _EOF_Count("kl-cancel")
}
KL_FlushShutdownReady(a := 0, b := 0, &Reason := "") {
	return true
}
KL_AppCat_PrepareShutdown(*) {
	return true
}
CB_PrepareShutdown(*) {
	return true
}
HotstringPrefixWatcherPrepareShutdown(*) {
	return true
}
LLM_Deps_PrepareShutdown(*) {
	return true
}
CrashReportWorker_StopAll(*) {
	return true
}
KLPF_CancelAll(*) {
	return true
}
_TooltipLogRenderAccounting(*) {
	return true
}
ReloadTerminalHandoffCommit(*) {
	return true
}
_Updater_SignalFinalExitForIntent(*) {
	return true
}
_Updater_TransferExitIntentAfterShutdownGates(*) {
	return true
}
_Updater_CompleteRecoveryHandoffOnExit(*) {
	return true
}
UninstallCancel(*) {
	return true
}
UninstallCommit(*) {
	return true
}
_LifecycleForceReleaseHeldInput(*) {
	return 1
}
KL_Stop(*) {
	return true
}
SFD_Stop(*) {
	return true
}
AltGrFamilyStopFollowing(*) {
	return true
}
MenuPopulation_Shutdown(*) {
	return true
}
MenuStartupCommands_Shutdown(*) {
	return true
}
DriverControl_Stop(*) {
	return true
}
FieldRun_Stop(*) {
	return true
}
HealthCheck_StopWindowControl(*) {
	return true
}
WebView_StopBrowserWarmup(*) {
	return true
}
WPMTrayReadout_Shutdown(*) {
	return true
}
MenuDispatcher_Shutdown(*) {
	return true
}
_LifecycleApplyQuitLayout(*) {
	return _EOF_Count("quit-layout")
}
PauseLayoutSwitch_IsUserQuit(Reason) {
	return Reason = "Menu" || Reason = "Exit"
}
_Updater_DeferExitIntentRetry(*) {
	return _EOF_Count("updater-retry")
}
_Updater_DeferRecoveryHandoffRetry(*) {
	return true
}
_Updater_ExitInvocationOwner(*) {
	global _EOF_Scenario
	return _EOF_Scenario == "updater" ? Map("Id", 1) : 0
}
MenuCommandConfigBusy(*) {
	return false
}
HSE_TerminalTransactionPending(*) {
	return false
}
_ConfigFullSaveHasPending(*) {
	return false
}
TimerArmOneShotMs(Callback, Ms) {
	SetTimer(Callback, -Ms)
}
TickExpired(Started, Ms, Now := unset) {
	return A_TickCount - Started >= Ms
}





; ==============================
; ==============================
; ======= 2/ The refusal =======
; ==============================
; ==============================

; The flush this exit interrupted resumes only once OnExit returned.
_EOF_Release() {
	global _EOF_Held
	_EOF_Held := false
}
LoggerPrepareShutdown(&Refusal := 0, *) {
	global _EOF_Held, _EOF_Scenario
	Refusal := 0
	if !_EOF_Held
		return true
	Sink := _EOF_Scenario == "sink"
	Refusal := Map("phase", "repair", "flush_active", Sink ? 0 : 1, "append_owners", Sink ? 0 : 1,
		"append_repairs", 0, "last_append_failure", Sink ? "write" : "none")
	if !Sink && _EOF_Scenario != "budget"
		SetTimer(_EOF_Release, -30)
	return false
}
LoggerFlushSettled() {
	global _EOF_Held
	return !_EOF_Held
}
FileReadActivityBusy() {
	global _EOF_Scenario, _EOF_ReadBusy
	return _EOF_Scenario == "read" && _EOF_ReadBusy
}
_EOF_ReadEnds() {
	global _EOF_ReadBusy
	_EOF_ReadBusy := false
}





; ==============================
; ==============================
; ======= 3/ The receipt =======
; ==============================
; ==============================

_EOF_Receipt(Exited) {
	global _EOF_State, _LifecycleShutdownReason, _LifecycleShutdownVetoAttempts
	global _LifecycleFlushExitRetryArmed, _EOF_ReceiptPath
	Text := "exited=" . Exited . " reason=" . _LifecycleShutdownReason
		. " vetoes=" . _LifecycleShutdownVetoAttempts
		. " armed=" . (_LifecycleFlushExitRetryArmed ? 1 : 0)
		. " errors=" . _EOF_State.Get("errors", 0)
		. " notices=" . _EOF_State.Get("notices", 0)
		. " updater=" . _EOF_State.Get("updater-retry", 0)
		. " quit_layout=" . _EOF_State.Get("quit-layout", 0)
		. " error=" . _EOF_State.Get("last_error", "")
		. " infos=" . _EOF_State.Get("infos", "")
	FileAppend(Text, _EOF_ReceiptPath, "UTF-8-RAW")
}

_EOF_OnAccepted(Reason, Code) {
	_EOF_Receipt(1)
	return 0
}

; Ends a process whose exit stayed refused; the receipt says so.
_EOF_GiveUp() {
	global _LifecycleFlushExitRetryArmed
	if _LifecycleFlushExitRetryArmed {
		SetTimer(_EOF_GiveUp, -50)
		return
	}
	_EOF_Receipt(0)
	OnExit(Ergopti_OnShutdown, 0)
	OnExit(_EOF_OnAccepted, 0)
	ExitApp(9)
}

_EOF_Run(Scenario) {
	global _EOF_Scenario, _EOF_Held, _EOF_ReadBusy, LIFECYCLE_FLUSH_EXIT_BUDGET_MS
	_EOF_Scenario := Scenario
	_EOF_Held := Scenario != "read"
	_EOF_ReadBusy := Scenario == "read"
	if Scenario == "read"
		SetTimer(_EOF_ReadEnds, -30)
	if Scenario == "budget"
		LIFECYCLE_FLUSH_EXIT_BUDGET_MS := 150
	OnExit(Ergopti_OnShutdown, -1)
	OnExit(_EOF_OnAccepted, 1)
	SetTimer(_EOF_GiveUp, Scenario == "sink" || Scenario == "updater" ? -500 : -1500)
	if Scenario == "logoff" {
		; AutoHotkey's own WM_ENDSESSION cannot be sent to a test: the handler is
		; called with its reason, and the retry must keep that reason.
		Ergopti_OnShutdown("Logoff", 5)
	} else if Scenario == "updater"
		ExitApp()
	else
		ActivateExitApp()
}

try {
	if A_Args.Length != 2
		throw Error("the harness needs a scenario and a receipt path")
	_EOF_ReceiptPath := A_Args[2]
	_EOF_Run(A_Args[1])
	Persistent()
} catch as Err {
	FileAppend(Err.Message, "**", "UTF-8-RAW")
	ExitApp(1)
}
