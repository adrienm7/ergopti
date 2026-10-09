; infra/uninstall.ahk
;
; ==============================================================================
; MODULE: Confirmed Portable Application Removal
; DESCRIPTION:
; A separate worker recycles only this compiled executable. It receives an exact
; parent process handle and cannot remove anything until the normal shutdown
; coordinator has accepted every refusal gate and explicitly signals COMMIT.
; ==============================================================================

; The holder is initialized on first use, including in the headless test runner.
#Include tick_count.ahk

UninstallState() {
	static State := Map()
	return State
}

; Closes owned native handles; cancellation terminates only this exact worker.
_UninstallClose(Owner, Cancel) {
	Info := Owner.Get("ProcessInfo", 0)
	if (Info is Buffer) {
		Process := NumGet(Info, 0, "Ptr")
		Thread := NumGet(Info, A_PtrSize, "Ptr")
		NumPut("Ptr", 0, Info, 0)
		NumPut("Ptr", 0, Info, A_PtrSize)
		if Cancel && Process {
			if !PLC_TerminateProcessHandle(Process)
				LoggerError("Uninstall", "Could not cancel the exact removal worker.")
			PLC_WaitHandle(Process, 5000)
		}
		PLC_CloseNativeHandle(Thread)
		PLC_CloseNativeHandle(Process)
	}
	for Key in ["Parent", "Ready", "Commit"] {
		PLC_CloseNativeHandle(Owner.Get(Key, 0))
		Owner[Key] := 0
	}
	if Cancel && FileExist(Owner.Get("Script", "")) {
		try FileDelete(Owner["Script"])
		catch as Err
			LoggerWarn("Uninstall", "Temporary worker cleanup failed: {1}.", Err.Message)
	}
}

; A refused or superseded exit revokes the pending removal permanently.
UninstallCancel() {
	State := UninstallState()
	if !State.Has("Owner")
		return
	Owner := State["Owner"]
	State.Delete("Owner")
	_UninstallClose(Owner, true)
	LoggerInfo("Uninstall", "Removal authorization was canceled.")
}

; Called only after shutdown has become terminal, never from a menu callback.
UninstallCommit(Reason) {
	State := UninstallState()
	if !State.Has("Owner")
		return true
	Owner := State["Owner"]
	if Reason != "Exit" || Owner.Get("Phase", "") != "Ready" {
		UninstallCancel()
		return false
	}
	Info := Owner["ProcessInfo"]
	if PLC_WaitHandle(NumGet(Info, 0, "Ptr"), 0) != 0x102
		|| !PLC_SetEventHandle(Owner["Commit"]) {
		UninstallCancel()
		LoggerError("Uninstall", "The removal worker did not accept terminal authorization.")
		Ui_MsgBox(t("dialog.uninstall.failed"), t("dialog.uninstall.window_title"), "Icon!")
		return false
	}
	State.Delete("Owner")
	_UninstallClose(Owner, false)
	LoggerInfo("Uninstall", "Removal worker authorized to wait for this process's exit.")
	return true
}

; The source checkout is never an uninstall target. Personal data and cached
; assets are deliberately outside this operation's single-file authority.
; On a source run the About row is greyed and names why, so a click that still
; arrives does nothing: it is logged, with no failure dialog for a removal that
; was never possible.
ShowUninstallErgopti(*) {
	global _VendorDir
	if Updater_IsLocalSource() {
		LoggerInfo("Uninstall", "Uninstall ignored: this is a local version run from source, with nothing to remove.")
		return false
	}
	State := UninstallState()
	if State.Has("Owner")
		return false
	Owner := Map("Phase", "Confirming")
	State["Owner"] := Owner
	try {
		ExecutableDigest := CryptoSha256Bytes(FileRead(A_ScriptFullPath, "RAW"))
		if !RegExMatch(ExecutableDigest, "^[0-9a-f]{64}$")
			throw Error("Could not capture the executable identity")
	} catch as Err {
		if State.Get("Owner", 0) == Owner
			UninstallCancel()
		LoggerError("Uninstall", "Executable identity capture failed: {1}.", Err.Message)
		Ui_MsgBox(t("dialog.uninstall.failed"), t("dialog.uninstall.window_title"), "Icon!")
		return false
	}
	if Ui_MsgBox(t("dialog.uninstall.confirm"), t("dialog.uninstall.window_title"), "YesNo Default2 Icon?") != "Yes" {
		if State.Get("Owner", 0) == Owner
			UninstallCancel()
		return false
	}
	if State.Get("Owner", 0) != Owner
		return false
	Owner["Phase"] := "Preparing"
	try {
		RandomBytes := Buffer(16)
		if DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", RandomBytes,
			"UInt", RandomBytes.Size, "UInt", 2, "UInt") != 0
			throw Error("Could not create a private uninstall identity")
		Nonce := ""
		Loop RandomBytes.Size
			Nonce .= Format("{:02x}", NumGet(RandomBytes, A_Index - 1, "UChar"))
		ReadyName := "Local\ErgoptiPlus.Uninstall.Ready." . Nonce
		CommitName := "Local\ErgoptiPlus.Uninstall.Commit." . Nonce
		Owner["Script"] := A_Temp . "\ergopti-uninstall-" . Nonce . ".ps1"
		FileCopy(_VendorDir . "\ergopti_uninstall.ps1", Owner["Script"], false)
		Owner["Ready"] := PLC_CreateNamedManualResetEvent(ReadyName)
		Owner["Commit"] := PLC_CreateNamedManualResetEvent(CommitName)
		Owner["Parent"] := PLC_OpenCurrentProcessHandle(0x100000)
		if !Owner["Parent"]
			throw Error("Could not acquire the exact parent process")
		PowerShell := _Updater_PowerShellPath()
		Args := [PowerShell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", Owner["Script"], "-ParentHandle", Owner["Parent"],
			"-ReadyName", ReadyName, "-CommitName", CommitName,
			"-ExpectedHash", ExecutableDigest,
			"-Executable", A_ScriptFullPath, "-FailureTitle", t("dialog.uninstall.window_title"),
			"-FailureText", t("dialog.uninstall.failed")]
		Command := ""
		for Arg in Args
			Command .= (Command == "" ? "" : " ") . _Updater_QuoteCreateProcessArg(Arg)
		CommandBuffer := Buffer((StrLen(Command) + 1) * 2, 0)
		StrPut(Command, CommandBuffer, "UTF-16")
		Startup := Buffer(A_PtrSize == 8 ? 104 : 68, 0)
		NumPut("UInt", Startup.Size, Startup, 0)
		Info := Buffer(A_PtrSize * 2 + 8, 0)
		Owner["ProcessInfo"] := Info
		PLC_CreateProcessWithInheritedHandles(PowerShell, CommandBuffer, 0x08000004, Startup, Info)
		if !State.Has("Owner") || State["Owner"] != Owner
			throw Error("Removal was canceled during worker creation")
		Resumed := PLC_ResumeThreadHandle(NumGet(Info, A_PtrSize, "Ptr"))
		if Resumed["Value"] == 0xFFFFFFFF
			throw Error("Could not resume the removal worker")
		_UninstallAwaitReady(Owner, Info)
		Owner["Phase"] := "Ready"
		ExitApp()
		; ExitApp returns only when an OnExit owner refuses the shutdown.
		UninstallCancel()
		Ui_MsgBox(t("dialog.uninstall.failed"), t("dialog.uninstall.window_title"), "Icon!")
		return false
	} catch as Err {
		if State.Get("Owner", 0) == Owner
			UninstallCancel()
		else
			; Cancellation can run just before CreateProcess writes the shared
			; buffer. Clean the local owner even after its global slot was revoked.
			_UninstallClose(Owner, true)
		LoggerError("Uninstall", "Removal preparation failed: {1}.", Err.Message)
		Ui_MsgBox(t("dialog.uninstall.failed"), t("dialog.uninstall.window_title"), "Icon!")
		return false
	}
}

/** Waits for this owner's READY capability without caching revocable handles. */
_UninstallAwaitReady(Owner, Info, ClockFn := unset, WaitFn := unset, SleepFn := unset) {
	Clock := IsSet(ClockFn) ? ClockFn : () => A_TickCount
	Wait := IsSet(WaitFn) ? WaitFn : PLC_WaitHandle
	Nap := IsSet(SleepFn) ? SleepFn : Sleep
	Started := Clock.Call()
	while Wait.Call(Owner.Get("Ready", 0), 0) != 0 {
		if TickElapsed64(Started, Clock.Call()) > 10000 || Wait.Call(NumGet(Info, 0, "Ptr"), 0) != 0x102
			throw Error("The removal worker did not become ready")
		Nap.Call(20)
	}
	return true
}
