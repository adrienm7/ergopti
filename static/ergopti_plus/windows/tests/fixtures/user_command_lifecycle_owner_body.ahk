; tests/fixtures/user_command_lifecycle_owner_body.ahk
; Real private cmd.exe and suspend reactor; no actual typing/clipboard output.
#Requires AutoHotkey v2.0

class _UCLC_State {
	static Mode := ""
	static Typed := []
	static Copied := []
	static Notices := []
	static Refusals := 0
	static LifecycleCalls := 0
	static EnvironmentOwner := 0
	static Pid := 0
	static Diagnostics := []
	static Successes := 0
	static NativeCreates := 0
	static NativeOwner := 0
}

_UCLC_Log(Line) {
	if InStr(Line, "[UserActions]", true) && InStr(Line, "exited with code 0.", true)
		_UCLC_State.Successes += 1
	if InStr(Line, "[ERROR]", true) && !(InStr(Line, "[Lifecycle]", true)
		&& InStr(Line, "transition owner 'user-programs' failed:", true))
		_UCLC_State.Diagnostics.Push(Line)
}

; Observe genuine successful native construction without replacing the
; constructor or manufacturing a job receipt. The real tuple is returned intact.
_UCLC_NativeCreate(Self, Executable, Command, CapturePath, Carrier) {
	_SR_TreeCreateSuspendedForState.DeleteProp("Call")
	try Native := _SR_TreeCreateSuspendedForState(Executable, Command, CapturePath, Carrier)
	finally _SR_TreeCreateSuspendedForState.DefineProp("Call", {Call: _UCLC_State.NativeOwner})
	if Executable == _UserActionComSpec() && Native is Map && Native.Get("Pid", 0) > 0
		_UCLC_State.NativeCreates += 1
	return Native
}

t(Key) => Key
CB_Write(*) => _LCPC_Require(false, "The explicit copy recorder must own all clipboard output.")
SendFinalResult(*) => _LCPC_Require(false, "The explicit type recorder must own all text output.")

_UCLC_RefuseTermination(*) {
	_UCLC_State.Refusals += 1
	return false
}

_UCLC_Lifecycle(Acquiring := false) {
	global _UserProgramPaused
	_UCLC_State.LifecycleCalls += 1
	Suspend(true)
	_LCPC_Require(A_IsSuspended, "Native Suspend must precede the actual suspend reactor.")
	Enter := Ergopti_OnSuspendEnter()
	EnterDebt := LifecycleTransitionDebtSnapshot("suspend")
	for Debt in EnterDebt
		_LCPC_Require(Debt.owner == "user-programs", "Only the exact command's refused retirement may leave suspend debt.")
	_LCPC_Require(_UserProgramPaused && (Acquiring || (!Enter && EnterDebt.Length == 1)),
		"The actual program owner must be paused; a refused running handle cannot acknowledge retirement.")
	Suspend(false)
	_LCPC_Require(!A_IsSuspended, "Native Resume must precede the actual resume reactor.")
	Resume := Ergopti_OnSuspendResume()
	ResumeDebt := LifecycleTransitionDebtSnapshot("resume")
	for Debt in ResumeDebt
		_LCPC_Require(Debt.owner == "user-programs", "Only the same exact command may retain resume debt.")
	_LCPC_Require(!_UserProgramPaused && (Acquiring || (!Resume && ResumeDebt.Length == 1)),
		"The real resume must run its program owner while physical command debt remains explicit.")
	FileAppend("OBS user-command-lifecycle enter=" . Enter . " enter_debt=" . EnterDebt.Length
		. " resume=" . Resume . " resume_debt=" . ResumeDebt.Length . "`n", "*")
}

; Delegates the actual native environment construction, then forces the admitted
; lifecycle boundary before that exact call returns to the real Start body.
_UCLC_EnvironmentReturn(Self, Added) {
	global _UserCommandEntries
	_LCPC_Require(_UserCommandEntries.Has("gesture__tap_3") && !_UserCommandEntries["gesture__tap_3"].Has("handle"),
		"The acquisition cut must precede native handle publication.")
	_UserCommandEnvironment.DeleteProp("Call")
	try Environment := _UserCommandEnvironment(Added)
	finally _UserCommandEnvironment.DefineProp("Call", {Call: _UCLC_State.EnvironmentOwner})
	_UCLC_Lifecycle(true)
	return Environment
}

_UCLC_Main() {
	global _LCPC_World, _ConfigDir, _SharedDir, _UserActionPorts, GestureActionParameters, _UserCommandEntries
	_LCPC_Require(A_Args.Length == 3, "An owned mode, directory and shared source are required.")
	Mode := A_Args[1], Directory := A_Args[2]
	_LCPC_Require(Mode == "current-type" || Mode == "retired-type" || Mode == "retired-copy" || Mode == "acquire-resume", "Unknown private command mode.")
	_UCLC_State.Mode := Mode
	_LCPC_World := {Ports: Map()}
	_ConfigDir := Directory, _SharedDir := A_Args[3]
	TimingsLoadShared(_SharedDir), KeystatsWalkerLoadTimings()
	LoggerSetTestSink(_UCLC_Log)
	_LCPC_Require(!A_IsSuspended && _UserCommandEntries.Count == 0, "The private command/lifecycle owners must start empty.")
	_UserActionPorts := Map("notify", (Text) => _UCLC_State.Notices.Push(Text),
		"type", (Text) => (_UCLC_State.Typed.Push(Text), true),
		"copy", (Text) => (_UCLC_State.Copied.Push(Text), true),
		"open_terminal", (*) => _LCPC_Require(false, "No terminal window may open."),
		"shell_open", (*) => _LCPC_Require(false, "No shell target may open."))
	Script := Directory . "\wait.cmd", Ready := Directory . "\ready", Gate := Directory . "\release", ReceiptPath := Directory . "\stdout.receipt"
	Batch := '@echo off`r`n>"' . Ready . '" echo READY`r`n:waiting`r`nif exist "' . Gate . '" goto completed`r`n>nul ping -n 2 127.0.0.1`r`ngoto waiting`r`n:completed`r`necho ERGOPTI_PRIVATE_COMMAND_LIFECYCLE`r`ncopy /b /y "%ERGOPTI_USER_COMMAND_OUT%" "' . ReceiptPath . '" >nul`r`nif errorlevel 1 exit /b 17`r`n'
	_LCPC_Require(FSWriteCreateDurable(Script, Batch) == 1, "The private batch must be exclusively created.")
	Output := Mode == "retired-copy" ? "copy" : "type"
	GestureActionParameters := Map(GestureActionParameterKey("gesture__tap_3", "run_command"),
		UserActionSpellCommand('call "' . Script . '"', "hidden", Output))
	Handle := 0, RealTerminate := 0
	try {
		_LCPC_Require(!_SR_TreeCreateSuspendedForState.HasOwnProp("Call"), "No external observer may own the native constructor.")
		_UCLC_State.NativeOwner := _UCLC_NativeCreate
		_SR_TreeCreateSuspendedForState.DefineProp("Call", {Call: _UCLC_State.NativeOwner})
		if Mode == "acquire-resume" {
			_LCPC_Require(!_UserCommandEnvironment.HasOwnProp("Call"), "No external observer may own the environment function.")
			_UCLC_State.EnvironmentOwner := _UCLC_EnvironmentReturn
			_UserCommandEnvironment.DefineProp("Call", {Call: _UCLC_State.EnvironmentOwner})
		}
		try Started := UserActions_RunCommand("gesture__tap_3")
		finally {
			_LCPC_Require(_SR_TreeCreateSuspendedForState.HasOwnProp("Call")
				&& _SR_TreeCreateSuspendedForState.GetOwnPropDesc("Call").Call == _UCLC_State.NativeOwner,
				"The fixture must retire only its exact native construction observer.")
			_SR_TreeCreateSuspendedForState.DeleteProp("Call")
			_UCLC_State.NativeOwner := 0
			if IsObject(_UCLC_State.EnvironmentOwner) {
				_LCPC_Require(_UserCommandEnvironment.HasOwnProp("Call")
					&& _UserCommandEnvironment.GetOwnPropDesc("Call").Call == _UCLC_State.EnvironmentOwner,
					"The fixture must retire only its exact environment observer.")
				_UserCommandEnvironment.DeleteProp("Call")
				_UCLC_State.EnvironmentOwner := 0
			}
		}
		if Started {
			_LCPC_Require(_UserCommandEntries.Has("gesture__tap_3"), "A successful start must publish its actual command entry.")
			Entry := _UserCommandEntries["gesture__tap_3"], Handle := Entry["handle"]
			RealTerminate := Handle.terminate
			_UCLC_State.Pid := Handle.processId()
			Begin := A_TickCount
			while !FileExist(Ready) && TickElapsed64(Begin) < 5000 {
				_SR_TreePoll()
				Sleep(10)
			}
			_LCPC_Require(FileExist(Ready) && _UCLC_State.Pid > 0 && !Entry["finished"],
				"The actual child-owned cmd tree must signal readiness and remain gated before lifecycle/output.")
			if Mode == "retired-type" || Mode == "retired-copy" {
				Handle.terminate := _UCLC_RefuseTermination
				_UCLC_Lifecycle()
				_LCPC_Require(_UCLC_State.Refusals >= 2 && _UserCommandEntries.Get("gesture__tap_3", 0) == Entry,
					"Both real lifecycle phases must retain the exact refused command owner.")
				Handle.terminate := RealTerminate
			}
			_LCPC_Require(FSWriteCreateDurable(Gate, "release") == 1, "Only the fixture may release its waiting batch.")
			Begin := A_TickCount
			while _UserCommandEntries.Has("gesture__tap_3") && TickElapsed64(Begin) < 7000 {
				_SR_TreePoll()
				Sleep(10)
			}
			_LCPC_Require(!_UserCommandEntries.Has("gesture__tap_3") && Entry["finished"],
				"The genuine tree completion must retire the public command entry before verdict.")
		}
		NativeCanary := false
		if FileExist(ReceiptPath) {
			ReceiptText := FSReadStrict(ReceiptPath)
			NativeCanary := RTrim(StrReplace(ReceiptText, "`r`n", "`n"), "`r`n") == "ERGOPTI_PRIVATE_COMMAND_LIFECYCLE"
			_LCPC_Require(NativeCanary, "The native batch's independent copy of actual stdout must contain its exact canary.")
		}
		_LCPC_Require(_UCLC_State.Successes == 0 || NativeCanary,
			"A natural successful completion must authenticate actual native stdout independently of the delivery reader.")
		FileAppend("OBS user-command mode=" . Mode . " started=" . Started . " pid=" . _UCLC_State.Pid
			. " native_creates=" . _UCLC_State.NativeCreates . " native_canary=" . NativeCanary . " lifecycle=" . _UCLC_State.LifecycleCalls . " refusal=" . _UCLC_State.Refusals
			. " typed=" . _UCLC_State.Typed.Length . " copied=" . _UCLC_State.Copied.Length
			. " notices=" . _UCLC_State.Notices.Length . " diagnostics=" . _UCLC_State.Diagnostics.Length . " pending=" . _UserCommandEntries.Count . "`n", "*")
		for Diagnostic in _UCLC_State.Diagnostics
			FileAppend("OBS user-command-diagnostic " . Diagnostic . "`n", "*")
		_LCPC_Require(_UCLC_State.Diagnostics.Length == 0, "No caught command/transport exception may masquerade as cancelled output.")
		_LCPC_Require(_UCLC_State.Notices.Length == 0, "The actual command cannot fail due to a missing prerequisite or transport error.")
		if Mode == "current-type" {
			_LCPC_Require(Started && _UCLC_State.Typed.Length == 1 && _UCLC_State.Copied.Length == 0
				&& _UCLC_State.Typed[1] == "ERGOPTI_PRIVATE_COMMAND_LIFECYCLE", "The current public command must deliver its exact native stdout once.")
		} else {
			_LCPC_Require(_UCLC_State.LifecycleCalls == 1, "Each revoked request must cross one genuine suspend/resume cycle.")
			_LCPC_Require(_UCLC_State.Typed.Length == 0 && _UCLC_State.Copied.Length == 0,
				"A request retired by suspension cannot publish its old output after resume.")
			if Mode == "acquire-resume"
				_LCPC_Require(!Started && _UCLC_State.Pid == 0 && _UCLC_State.NativeCreates == 0, "A revoked acquisition cannot create a native command tree after resume.")
		}
	} finally {
		Suspend(false)
		if IsObject(Handle) {
			if IsObject(RealTerminate)
				Handle.terminate := RealTerminate
			Receipt := Handle.terminate()
			_LCPC_Require(Receipt is Integer && Receipt == 1, "The actual native tree must retire before the child exits.")
		}
		_LCPC_Require(ProgramActions_Stop(false), "Real command/program cleanup must acknowledge after native retirement.")
		LoggerClearTestSink()
	}
}
try {
	_UCLC_Main()
	FileAppend("PASS usercommand-lifecycle " . A_Args[1] . "`n", "*")
	ExitApp(0)
} catch Any as UCLCEntryFailure {
	FileAppend("FAIL usercommand-lifecycle " . UCLCEntryFailure.Message . " line=" . UCLCEntryFailure.Line . "`n", "*")
	ExitApp(1)
}
