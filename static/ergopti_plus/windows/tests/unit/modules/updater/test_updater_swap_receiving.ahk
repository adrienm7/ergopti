; tests/unit/modules/updater/test_updater_swap_receiving.ahk

; ==============================================================================
; MODULE: Updater Swap Receiving Scenarios
; DESCRIPTION:
; The native swap and boot-ready receiving scenarios of the Windows updater
; recovery audit (docs/audits/platform-parity/2026-11-04-recovery/
; windows-updater). Unlike test_updater_swap_transaction.ahk, whose current
; and new "executables" are batch files and whose parent is a separate gate,
; here every executable is a real PE image: copies of the AutoHotkey runtime
; told apart by a trailing marker, each running the ErgoptiPlus.ahk beside it.
; The parent is the canonical ErgoptiPlus.exe itself, so its image is locked
; until it exits, as an installed driver's is. The production owner creates the
; suspended worker, the shipped swap script replaces the running image after
; the four-event handshake, and the relaunched executable acknowledges through
; the inherited boot-ready event:
; 1. the new executable boots: it replaces the old one, nothing is left behind;
; 2. the new executable exits before boot-ready: the old one is restored and
;    relaunched, and the terminal receipt names the failure;
; 3. the parent dies before FinalExit: nothing is touched.
; Registered as interactive: only the receiving runner selects them.
; ==============================================================================

#Requires AutoHotkey v2.0

; The trailing bytes that tell the executable images apart.
global PWRU_MARKER_PREFIX := "ERGOPTI-RECEIVING-MARKER:"
; Exit code of a relaunched image told to refuse its boot.
global PWRU_REFUSED_BOOT_EXIT := 9

; Copies the AutoHotkey runtime to Path and appends its marker as an overlay,
; which the PE loader ignores.
_PWRU_WriteImage(Path, Label) {
	global PWRU_MARKER_PREFIX
	FileCopy(A_AhkPath, Path)
	Writer := FileOpen(Path, "a")
	try Writer.Write(PWRU_MARKER_PREFIX . Label)
	finally Writer.Close()
}

; The marker of an executable image, or "" when it has none.
_PWRU_ImageLabel(Path) {
	global PWRU_MARKER_PREFIX
	if !FileExist(Path)
		return ""
	Reader := FileOpen(Path, "r")
	try {
		Width := StrLen(PWRU_MARKER_PREFIX) + 3
		Reader.Pos := Reader.Length - Width
		Tail := Reader.Read(Width)
	} finally Reader.Close()
	return SubStr(Tail, 1, StrLen(PWRU_MARKER_PREFIX)) == PWRU_MARKER_PREFIX ? SubStr(Tail, StrLen(PWRU_MARKER_PREFIX) + 1) : ""
}

; The boot script both images run when started without a script argument: it
; records its launch, then acknowledges the inherited boot-ready event the way
; the driver does (_Updater_ValidateBootReadyEventName, PLC_SignalNamedEvent),
; unless a refuse.<label> file tells it to exit first; it then stays alive
; until the scenario releases it, so the worker's probation sees a live driver.
_PWRU_WriteBootScript(CurrentExe, ReleaseName) {
	global PWRU_MARKER_PREFIX, PWRU_REFUSED_BOOT_EXIT
	Script := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
		. "Image := FileOpen(A_AhkPath, 'r')`nImage.Pos := Image.Length - " . (StrLen(PWRU_MARKER_PREFIX) + 3) . "`n"
		. "Label := SubStr(Image.Read(" . (StrLen(PWRU_MARKER_PREFIX) + 3) . "), " . (StrLen(PWRU_MARKER_PREFIX) + 1) . ")`nImage.Close()`n"
		. "FileAppend(Label . '``n', A_ScriptDir . '\launches.log', 'UTF-8-RAW')`n"
		. "if FileExist(A_ScriptDir . '\refuse.' . Label)`n`tExitApp(" . PWRU_REFUSED_BOOT_EXIT . ")`n"
		. "Name := EnvGet('ERGOPTI_UPDATER_BOOT_READY')`n"
		. "if !RegExMatch(Name, '^Local\\ErgoptiPlus\.Updater\.BootReady\.[0-9a-fA-F]{32}$')`n`tExitApp(8)`n"
		. "Ready := DllCall('OpenEventW', 'UInt', 0x0002, 'Int', false, 'Str', Name, 'Ptr')`n"
		. "if !Ready || !DllCall('SetEvent', 'Ptr', Ready, 'Int')`n`tExitApp(7)`n"
		. "DllCall('CloseHandle', 'Ptr', Ready)`n"
		. "Release := DllCall('OpenEventW', 'UInt', 0x00100000, 'Int', false, 'Str', '" . ReleaseName . "', 'Ptr')`n"
		. "if Release`n`tDllCall('WaitForSingleObject', 'Ptr', Release, 'UInt', " . _USTX_WorkerCompletionTimeoutMs() . ")`n"
		. "ExitApp(0)`n"
	; A compiled interpreter run without a script argument runs the script named
	; after it, beside it: the boot script takes the exe's own name.
	FileAppend(Chr(0xFEFF) . Script, RegExReplace(CurrentExe, "i)\.exe$", ".ahk"), "UTF-8-RAW")
}

; Runs one swap. Scenario: "boots", "refuses" or "parent-dies".
_PWRU_RunSwap(Scenario) {
	global UPDATER_SWAP_SYNCHRONIZE, USTX_PROCESS_TERMINATE, PWRU_REFUSED_BOOT_EXIT
	Dir := ReceivingScratchDir("updater-swap-" . Scenario)
	CurrentExe := Dir . "\ErgoptiPlus.exe"
	NewExe := Dir . "\staged\ErgoptiPlus.exe"
	SwapScript := Dir . "\staged\swap_update.ps1"
	Terminal := SwapScript . ".log.terminal"
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
	ReleaseName := "Local\ErgoptiReceivingRelease_" . TestId
	ParentGateName := "Local\ErgoptiReceivingParent_" . TestId
	Owner := 0, Job := 0, ReleaseHandle := 0, ParentGate := 0, ParentCleanup := 0, Failure := 0
	try {
		DirCreate(Dir . "\staged")
		_PWRU_WriteImage(CurrentExe, "OLD")
		_PWRU_WriteImage(NewExe, "NEW")
		_PWRU_WriteBootScript(CurrentExe, ReleaseName)
		if (Scenario == "refuses")
			FileAppend("", Dir . "\refuse.NEW")
		FileAppend(FileRead(_Updater_SwapWorkerPath(), "UTF-8"), SwapScript, "UTF-8-RAW")
		ReleaseHandle := _USTX_CreateFixtureEvent(ReleaseName)
		ParentGate := _USTX_CreateFixtureEvent(ParentGateName)

		; The parent is the running canonical image, as an installed driver is.
		Run('"' . CurrentExe . '" /force /ErrorStdOut "' . A_ScriptDir . '\support\updater_parent_gate.ahk" "' . ParentGateName . '"',
			Dir, "Hide", &ParentPid)
		ParentCleanup := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE | USTX_PROCESS_TERMINATE, "Int", false,
			"UInt", ParentPid, "Ptr")
		AssertTrue(ParentCleanup != 0, "the scenario owns an exact handle on the running parent")
		; Windows lets a running image be renamed, never written: the loader
		; maps it, which is what an in-place replacement would collide with.
		Locked := false
		try {
			Probe := FileOpen(CurrentExe, "rw")
			Locked := !IsObject(Probe)
			if !Locked
				Probe.Close()
		} catch
			Locked := true
		AssertTrue(Locked, "positive control: the running parent image cannot be opened for writing")
		ParentHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE, "Int", true, "UInt", ParentPid, "Ptr")
		AssertTrue(ParentHandle != 0, "the worker inherits an exact parent handle")

		Owner := _Updater_CreateSuspendedSwapOwner(SwapScript, NewExe, CurrentExe, 2000000 + Mod(A_TickCount, 1000000), ParentHandle)
		Job := DllCall("Kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
		AssertTrue(Job && DllCall("Kernel32\AssignProcessToJobObject", "Ptr", Job, "Ptr", Owner["ProcessHandle"], "Int"),
			"the worker tree is owned by the scenario")
		AssertTrue(_Updater_ResumeSwapOwner(Owner), "the suspended worker resumes")
		AssertTrue(_USTX_WaitForSwapSignal(Owner, "Ready"), "the worker signals Ready")
		AssertTrue(_Updater_SetSwapEvent(Owner["CommitHandle"]), "Commit is authorized")
		AssertTrue(_USTX_WaitForSwapSignal(Owner, "Ack"), "the worker acknowledges Commit")
		if (Scenario == "parent-dies") {
			AssertTrue(DllCall("TerminateProcess", "Ptr", ParentCleanup, "UInt", 1, "Int"), "the parent dies before FinalExit")
			AssertTrue(_USTX_WaitForProcessExit(Owner), "the worker ends with its parent")
			AssertEqual(21, _USTX_GetExitCode(Owner), "a parent gone before FinalExit is refused")
			AssertEqual("OLD", _PWRU_ImageLabel(CurrentExe), "the canonical image is untouched")
			AssertEqual("NEW", _PWRU_ImageLabel(NewExe), "the staged image is untouched")
			AssertFalse(FileExist(Dir . "\launches.log"), "nothing was launched")
			return
		}
		AssertTrue(_Updater_SetSwapEvent(Owner["FinalExitHandle"]), "FinalExit is authorized")
		AssertTrue(DllCall("SetEvent", "Ptr", ParentGate, "Int"), "the parent exits")
		AssertTrue(_USTX_WaitForProcessExit(Owner, _USTX_WorkerCompletionTimeoutMs()), "the worker finishes")
		ExitCode := _USTX_GetExitCode(Owner)
		Launches := FileExist(Dir . "\launches.log") ? FileRead(Dir . "\launches.log", "UTF-8-RAW") : ""
		if (Scenario == "boots") {
			AssertEqual(0, ExitCode, "the swap completes: " . _USTX_ReadDiagnostic(SwapScript . ".log"))
			AssertEqual("NEW", _PWRU_ImageLabel(CurrentExe), "the new image replaced the running one")
			AssertEqual("NEW`n", Launches, "only the new image was launched, and it acknowledged boot-ready")
			AssertFalse(FileExist(Terminal), "no failure receipt")
		} else {
			AssertEqual(1, ExitCode, "a refused boot fails the swap")
			AssertEqual("OLD", _PWRU_ImageLabel(CurrentExe), "the old image is restored")
			AssertEqual("NEW`nOLD`n", Launches, "the new image ran first, then the restored old one acknowledged boot-ready")
			AssertContains(FileRead(Terminal, "UTF-8"), "SWAP_ERROR:Driver exited before boot-ready",
				"the terminal receipt names the refused boot")
		}
		Leftovers := []
		loop files, Dir . "\*.exe*"
			if (A_LoopFileName != "ErgoptiPlus.exe")
				Leftovers.Push(A_LoopFileName)
		AssertEqual("", _PWRU_Join(Leftovers), "no backup, candidate, recovery or claim is left beside the canonical image")
	} catch as Err {
		Failure := Err
		Err.Message .= "`nswap log: " . _USTX_ReadDiagnostic(SwapScript . ".log")
		throw Err
	} finally {
		if (Owner is Map)
			_Updater_CloseSwapOwner(Owner, true)
		if ParentCleanup {
			if (_Updater_WaitHandleState(ParentCleanup) == 0)
				DllCall("TerminateProcess", "Ptr", ParentCleanup, "UInt", 1, "Int")
			_Updater_CloseNativeSwapHandle(ParentCleanup)
		}
		if ParentGate
			DllCall("CloseHandle", "Ptr", ParentGate, "Int")
		if ReleaseHandle {
			DllCall("SetEvent", "Ptr", ReleaseHandle, "Int")
			DllCall("CloseHandle", "Ptr", ReleaseHandle, "Int")
		}
		if Job && _USTX_CloseFixtureTree(Job, Failure)
			_USTX_DeleteFixtureAfterCase(Dir, Failure)
	}
}

_PWRU_Join(Items) {
	Text := ""
	for Item in Items
		Text .= (Text == "" ? "" : ", ") . Item
	return Text
}

for _PWRUScenario, _PWRUPhrase in Map("boots", "the new image acknowledges boot-ready",
		"refuses", "the new image exits before boot-ready", "parent-dies", "the parent dies before FinalExit")
	Test("updater swap receiving: the running image swap when " . _PWRUPhrase . " (phys-w-receiving-updater-swap)",
		_PWRU_RunSwap.Bind(_PWRUScenario), true)
