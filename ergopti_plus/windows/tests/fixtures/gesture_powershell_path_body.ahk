; tests/fixtures/gesture_powershell_path_body.ahk

; ==============================================================================
; MODULE: Gesture PowerShell Artifact Producer Child
; DESCRIPTION:
; Real public callers build and write their worker. Elevated Run and registry
; backup are passive boundaries. A native reservation timer is retained and
; cancelled while this private child remains Critical; no worker is executed.
; ==============================================================================

#Requires AutoHotkey v2.0

LoggerStart(*) => 0
LoggerSuccess(*) => 0
LoggerInfo(*) => 0
LoggerWarn(*) => 0
LoggerError(*) => 0

TouchpadRegistryEnsureBackup(*) {
	global _GPSE_Backups
	_GPSE_Backups += 1
	return true
}

_GPSE_Timer(Callback, Period) {
	global _GPSE_Timers
	_GPSE_Timers.Push(Callback)
	SetTimer(Callback, Period)
}

_GPSE_Run(Command, WorkingDir := "", Options := "", &Pid := 0) {
	global _GPSE_Runs, _GPSE_Command
	_GPSE_Runs += 1
	_GPSE_Command := Command
	Pid := 0
}

_GPSE_Done(*) {
	throw Error("An elevated worker callback cannot run in the artifact-only fixture.")
}

_GPSE_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_GPSE_Main() {
	global _GPSE_Timers := [], _GPSE_Runs := 0, _GPSE_Backups := 0, _GPSE_Command := ""
	global DriverPid := DllCall("GetCurrentProcessId", "UInt")
	global _OnboardingGestureJob, _GestureRestartJob
	if A_Args.Length != 2
		ExitApp(2)
	Primary := 0
	PreviousCritical := Critical("On")
	try {
		_GPSE_Require(StrCompare(RTrim(A_Temp, "\"), RTrim(A_Args[2], "\"), false) == 0,
			"The caller must read its actual private native TEMP directory.")
		_GPSE_Require(!A_IsSuspended, "Artifact production needs a live private child.")
		if A_Args[1] == "onboarding" {
			Accepted := _Onboarding_StartGestureAuto(_GPSE_Done)
			Job := _OnboardingGestureJob
		} else {
			_GPSE_Require(A_Args[1] == "restart", "Unknown artifact producer.")
			Accepted := GestureRestartTouchpadDevice(_GPSE_Done)
			Job := _GestureRestartJob
		}
		_GPSE_Require(Accepted && _GPSE_Runs == 1 && _GPSE_Timers.Length == 1,
			"The whole caller must reach its real writer and controlled launch once.")
		_GPSE_Require(_GPSE_Backups == (A_Args[1] == "onboarding" ? 1 : 0),
			"Only the explicit registry backup boundary may be bypassed.")
		_GPSE_Require(FileExist(Job["script"]) && !FileExist(Job["result"]),
			"The actual caller must publish a script without executing it.")
		_GPSE_Require(InStr(_GPSE_Command, '*RunAs powershell.exe ')
			&& InStr(_GPSE_Command, '-File "' . Job["script"] . '"'),
			"The observed real launch must reference its own written artifact.")
		FileAppend(Job["script"] . "`n" . Job["result"] . "`n", A_Args[2] . "\producer.receipt", "UTF-8-RAW")
	} catch as Failure {
		Primary := Failure
	} finally {
		for Callback in _GPSE_Timers
			SetTimer(Callback, 0)
		_GPSE_Timers.Length := 0
		_OnboardingGestureJob["done"] := 0
		_GestureRestartJob["done"] := 0
		Critical(PreviousCritical)
	}
	if IsObject(Primary) {
		FileAppend("FAIL gesture-powershell-producer " . Primary.Message . "`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS gesture-powershell-producer " . A_Args[1] . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_GPSE_Main()
