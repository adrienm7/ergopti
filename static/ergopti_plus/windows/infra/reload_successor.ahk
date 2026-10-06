; infra/reload_successor.ahk

; ==============================================================================
; MODULE: Reload Successor Process
; DESCRIPTION:
; OS seams of the reload hand-off (infra/reload_terminal_handoff.ahk): launching
; the successor with an owned process handle, probing it, stopping it, and the
; one-shot timers a pending record uses. Every probe and termination goes
; through the handle rather than the pid, so it can only ever reach the exact
; successor, even after its id is reused by another process.
; ==============================================================================

#Requires AutoHotkey v2.0

; Starts Target and returns the successor descriptor.
; @param Target {String} The command line to run.
; @param WorkingDir {String} The directory the successor starts in.
; @param Options {String} Run options, such as "Hide".
; @returns {Map} The successor's "pid" and owned process "handle".
ReloadSuccessorLaunch(Target, WorkingDir, Options := "") {
	global PLC_PROCESS_TERMINATE, PLC_SYNCHRONIZE
	ProcessId := 0
	Run(Target, WorkingDir, Options, &ProcessId)
	if !(ProcessId is Integer) || ProcessId <= 0
		throw Error("The reload successor started without a process id.")
	Handle := PLC_OpenProcessHandle(ProcessId,
		PLC_SYNCHRONIZE | PLC_PROCESS_TERMINATE)
	if !Handle {
		; An unowned successor could replace this instance after its caller was
		; told the reload failed. It is still loading, so stop it by id now.
		LastError := A_LastError
		ProcessClose(ProcessId)
		throw OSError(LastError, "OpenProcess",
			"The reload successor pid " . ProcessId . " could not be owned")
	}
	return Map("pid", ProcessId, "handle", Handle)
}

; The production port of ReloadTerminalInvoke.
ReloadSuccessorPort() {
	return Map(
		"alive", ReloadSuccessorAlive,
		"terminate", ReloadSuccessorTerminate,
		"close", ReloadSuccessorClose,
		"arm", TimerArmOneShotMs,
		"now", _ReloadSuccessorNow)
}

ReloadSuccessorAlive(Successor) {
	global PLC_WAIT_OBJECT_0, PLC_WAIT_TIMEOUT
	if Successor.Get("close_attempted", false) {
		if Successor.Get("close_acknowledged", false)
			return false
		throw Error("The reload successor handle close remains unacknowledged.")
	}
	Wait := PLC_WaitHandle(Successor["handle"], 0)
	if (Wait == PLC_WAIT_TIMEOUT)
		return true
	if (Wait == PLC_WAIT_OBJECT_0)
		return false
	throw OSError(A_LastError, "WaitForSingleObject",
		"The reload successor handle could not be waited on")
}

ReloadSuccessorTerminate(Successor) {
	if Successor.Get("close_attempted", false)
		throw Error("A reload successor handle cannot be used after native close was attempted.")
	return PLC_TerminateProcessHandle(Successor["handle"])
}

ReloadSuccessorClose(Successor) {
	if Successor.Get("close_attempted", false)
		return Successor.Get("close_acknowledged", false)
	Handle := Successor["handle"]
	Successor["close_attempted"] := true
	Successor["close_acknowledged"] := false
	Closed := PLC_CloseNativeHandle(Handle)
	if !((Closed is Integer) && Closed == 1)
		return false
	Successor["handle"] := 0
	Successor["close_acknowledged"] := true
	return true
}

_ReloadSuccessorNow() {
	return A_TickCount
}
