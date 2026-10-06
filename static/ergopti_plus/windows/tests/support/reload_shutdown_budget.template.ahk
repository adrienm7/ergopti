; tests/support/reload_shutdown_budget.template.ahk

; ==============================================================================
; MODULE: Reload Shutdown Budget Probe
; DESCRIPTION:
; Executes exact lifecycle admission functions against owned recording ports.
; First assertion failures remain terminal through separate cleanup diagnostics;
; runtime errors produce an explicit failure receipt and native exit code 1.
; ==============================================================================

#Requires AutoHotkey v2.0
#ErrorStdOut
#Warn All, StdOut
#NoTrayIcon
#Include @@LEASE@@
#Include @@HANDOFF@@

global LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS := 5
global _LifecycleShutdownVetoAttempts := 5
global _LifecycleShutdownReason := "Exit", _LifecycleAiShutdownAttempt := 1
global RQSBProbe := Map("alive", true, "terminated", 0, "closed", 0, "armed", [],
	"callbacks", 0, "force", 0, "kl", 0, "throw", false, "stop_result", true)
global RQSBMode := @@MODE@@
global RQSBFacadeFailure := 0





; =====================================
; =====================================
; ======= 1/ Recording fixtures =======
; =====================================
; =====================================

; The model never uses localization or notification; even a swallowed facade
; exception must poison its terminal diagnostic result.
_RQSB_UnexpectedFacade(RQSBFacadeName) {
	global RQSBFacadeFailure
	RQSBUnexpectedError := Error("UNEXPECTED fixture dependency call: " . RQSBFacadeName)
	if !(RQSBFacadeFailure is Error)
		RQSBFacadeFailure := RQSBUnexpectedError
	throw RQSBUnexpectedError
}

t(*) {
	return _RQSB_UnexpectedFacade("t")
}

NotifierSend(*) {
	return _RQSB_UnexpectedFacade("NotifierSend")
}

LoggerError(*) {
}
LoggerInfo(*) {
}
UninstallCancel() {
	return true
}
KL_CancelShutdown() {
	global RQSBProbe
	RQSBProbe["kl"] += 1
}
LLM_Menu_ApiPrivateRefuseShutdown(*) {
	return true
}
LLM_Menu_LocalServersShutdownRefused(*) {
	return true
}
_LifecycleForceReleaseHeldInput() {
	global RQSBProbe
	RQSBProbe["force"] += 1
	return 1
}
TickExpired(*) {
	return false
}
_RQSB_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_RQSB_Terminate(*) {
	global RQSBProbe
	RQSBProbe["terminated"] += 1
	if RQSBProbe["throw"]
		throw Error("controlled stop exception")
	return RQSBProbe["stop_result"]
}
_RQSB_Close(*) {
	global RQSBProbe
	RQSBProbe["closed"] += 1
	return true
}
_RQSB_Arm(Callback, DelayMs) {
	global RQSBProbe
	RQSBProbe["armed"].Push(Callback)
}
_RQSB_Drain() {
	global RQSBProbe
	Armed := RQSBProbe["armed"]
	RQSBProbe["armed"] := []
	for Callback in Armed
		Callback.Call()
}
_RQSB_Launch() {
	global RQSBMode, RQSBProbe, _ReloadTerminalHandoff
	if RQSBMode == "launching" {
		_RQSB_Require(_LifecycleRefuseShutdown("acquisition reentry") == 1,
			"The exact acquisition reservation cannot be forced out.")
		_RQSB_Require(_ReloadTerminalHandoff["state"] == "launching", "The launch remains owned.")
	}
	return Map("pid", 4242)
}
_RQSB_Refused(*) {
	global RQSBProbe
	RQSBProbe["callbacks"] += 1
}

@@BODY@@






; =======================================
; =======================================
; ======= 2/ Admission assertions =======
; =======================================
; =======================================

_RQSB_RunCase() {
	global RQSBProbe, RQSBMode, RQSBFacadeFailure
	Bundle := 0
	ReadActivity := 0
	Record := 0
	Completed := false
	FirstFailure := 0
	CleanupFailure := 0
	try {
		Bundle := _ConfigWriteTerminalTryAcquire([A_Temp . "/reload-budget-private.toml"])
		_RQSB_Require(Bundle is Object, "A real terminal bundle must be acquired.")
		Port := Map("alive", (*) => RQSBProbe["alive"], "terminate", _RQSB_Terminate,
			"close", _RQSB_Close, "arm", _RQSB_Arm, "now", (*) => 1000)
		_RQSB_Require(ReloadTerminalInvoke(Bundle, 0, _RQSB_Launch, Port,
			0, 0, _RQSB_Refused, _ConfigWriteTerminalRelease.Bind(Bundle)), "The exact process model is acquired.")
		Record := ReloadTerminalHandoffPending()
		_RQSB_Require(Record is Map, "The launched record must be registered.")
		if RQSBMode == "pending-read" {
			ReadActivity := FileReadActivityEnter(A_Temp . "/reload-budget-reader.toml")
			_RQSB_Require(FileReadActivityBusy(), "The earlier READV4 veto has real activity metadata.")
			loop 7 {
				_RQSB_Require(_LifecycleRefuseShutdown("a configuration read still owns native retirement") == 1,
					"An earlier read veto cannot force out its exact pending successor.")
				_RQSB_Require(ReloadTerminalHandoffPending() == Record && !Record["stop_requested"],
					"Earlier read refusal retains the pending owner without stopping before other gates.")
			}
			_RQSB_Require(FileReadActivityLeave(ReadActivity), "The opening-only activity can be exactly retired.")
			ReadActivity := 0
		}
		if RQSBMode == "false"
			RQSBProbe["stop_result"] := false
		if RQSBMode == "throw"
			RQSBProbe["throw"] := true
		_RQSB_Require(!ReloadTerminalHandoffPrepareAbandon(Record, "Exit"), "The successor is still physically live.")
		loop 7 {
			_RQSB_Require(_LifecycleRefuseNativeRetirement("a reload successor still owns native retirement") == 1,
				"The specific stop veto is never forced by the general ceiling.")
			_RQSB_Require(_LifecycleRefuseShutdown("an earlier read gate during stop") == 1,
				"A repeated earlier refusal must honor the same unquiesced owner.")
			_RQSB_Drain()
			_RQSB_Require(ReloadTerminalHandoffPending() == Record && !Record["stop_acknowledged"],
				"Repeated explicit exits preserve the same native debt.")
			_RQSB_Require(_ConfigWriteTerminalIsActive() && RQSBProbe["terminated"] == 1,
				"The bundle stays owned and native termination is requested only once.")
			_RQSB_Require(RQSBProbe["closed"] == 0 && RQSBProbe["callbacks"] == 0 && RQSBProbe["force"] == 0,
				"No close, delivery or forced-release fallback runs while the child is live.")
		}
		RQSBProbe["alive"] := false
		_RQSB_Drain()
		_RQSB_Require(Record["stop_acknowledged"] && Record["state"] == "abandon_ready", "Only terminal observation admits final retirement.")
		_RQSB_Require(ReloadTerminalHandoffAbandon(Record, "Exit"), "Final close follows physical terminal.")
		_ConfigWriteTerminalRelease(Bundle)
		_RQSB_Require(_LifecycleRefuseShutdown("unrelated exhausted refusal") == 0 && RQSBProbe["force"] == 1,
			"After exact native ownership retires the original ceiling still permits forced exit.")
		_RQSB_Require(_LifecycleShutdownVetoAttempts > LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS,
			"Repeated refusals retain the original counter instead of resetting its budget.")
		Completed := true
	} catch as RQSBFirstFailure {
		; Preserve the original assertion before cleanup can report its own failure.
		FirstFailure := RQSBFirstFailure
	} finally {
		try {
			if ReadActivity is Object
				FileReadActivityLeave(ReadActivity)
			if Record is Map && _ReloadTerminalHandoffOwns(Record) {
				RQSBProbe["alive"] := false
				loop 4
					_RQSB_Drain()
				if Record["state"] == "abandon_ready"
					ReloadTerminalHandoffAbandon(Record, "Exit")
				_RQSB_Require(!_ReloadTerminalHandoffOwns(Record), "Cleanup cannot discard its model's exact owner.")
			}
			_ConfigWriteTerminalRelease(Bundle)
		} catch as RQSBCleanupFailure {
			CleanupFailure := RQSBCleanupFailure
		}
	}





	; =====================================
	; =====================================
	; ======= 3/ Terminal failure result =======
	; =====================================
	; =====================================

	if (RQSBFacadeFailure is Error) && !(FirstFailure is Error)
		FirstFailure := RQSBFacadeFailure
	if (FirstFailure is Error) || (CleanupFailure is Error) || !Completed {
		Diagnostic := "failure`nfirst=" . ((FirstFailure is Error) ? FirstFailure.Message : "")
			. "`ncleanup=" . ((CleanupFailure is Error) ? CleanupFailure.Message : "") . "`n"
		try FileAppend(Diagnostic, @@RECEIPT@@, "UTF-8-RAW")
		catch as ReceiptFailure
			try FileAppend("receipt=" . ReceiptFailure.Message . "`n" . Diagnostic, "**", "UTF-8-RAW")
		ExitApp(1)
	}
	try FileAppend("qualified", @@RECEIPT@@, "UTF-8-RAW")
	catch as ReceiptFailure {
		try FileAppend("receipt=" . ReceiptFailure.Message . "`n", "**", "UTF-8-RAW")
		ExitApp(1)
	}
	ExitApp(0)
}

_RQSB_RunCase()
