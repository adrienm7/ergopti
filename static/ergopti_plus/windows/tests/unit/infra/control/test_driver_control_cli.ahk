; tests/unit/infra/control/test_driver_control_cli.ahk

; ==============================================================================
; MODULE: Windows Control CLI Native Receiving
; DESCRIPTION:
; Requires the actual Windows Node/PowerShell entrypoint alongside portable
; admission checks. Every artifact stays private; no driver is started or reloaded.
; ==============================================================================

_DCCLI_NativeAdmission(Phase) {
	global _DriverDir, _SR_TreeOwnedTasks, _SR_TreeCaptureDebts
	static TIMEOUT_MS := 90000
	Repo := FSResolveDirectoryPath(_DriverDir . "\..\..\..")
	Script := Repo . "\tools\test\test-windows-control-cli.cjs"
	AssertTrue(FileExist(Script), "the actual control CLI admission test must be present")
	Observed := [], Control := Map(), Handle := 0
	Capture(State, Native) {
		Control["state"] := State
		Control["capture_file"] := State["TmpFile"]
		Control["capture_directory"] := State["CaptureDir"]
	}
	try {
		Handle := ShellRunner_SpawnTreeOwned("node.exe", [Script, "--phase=" . Phase],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "output", Out)), , Capture)
		AssertTrue(Handle.start(), "the actual Windows control admission process must start")
		Started := A_TickCount
		while !TickExpired64(Started, TIMEOUT_MS) {
			_SR_TreePoll()
			if Observed.Length == 1 && Control.Has("state") {
				Claim := Control["state"]["TerminalClaim"]
				if Claim is Map && Claim["TreeQuiesced"] && !FileExist(Claim["TmpFile"]) && !DirExist(Claim["CaptureDir"])
					break
			}
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the actual control admission process must settle within its bound")
		AssertEqual(0, Observed[1]["exit"], "control admission output: " . Observed[1]["output"])
		Marker := "[OK] Windows control CLI " . Phase . " admission controls passed."
		Markers := 0
		for Line in StrSplit(StrReplace(Observed[1]["output"], "`r`n", "`n"), "`n") {
			if Line == Marker
				Markers += 1
		}
		AssertEqual(1, Markers, "an OS skip or missing PowerShell host cannot certify actual admission")
		AssertTrue(Control.Has("state"), "the native construction observer must retain its exact owner")
		State := Control["state"], Claim := State["TerminalClaim"]
		AssertTrue(Control["capture_file"] != "" && Control["capture_directory"] != "", "the actual CLI must own its bounded capture")
		AssertEqual(Control["capture_file"], Claim["TmpFile"], "completion must retain the original capture file identity")
		AssertEqual(Control["capture_directory"], Claim["CaptureDir"], "completion must retain the original capture directory identity")
		AssertTrue(Claim is Map && Claim["TreeQuiesced"], "the exact Node and PowerShell tree must be physically retired")
		AssertFalse(State["FinalizationPending"], "the completed admission cannot retain native finalization")
		for Key in ["ProcessHandle", "ThreadHandle", "JobHandle"] {
			AssertEqual(0, State[Key], "the original construction must release " . Key)
			AssertEqual(0, Claim[Key], "the terminal owner must release " . Key)
		}
		AssertEqual(0, Claim["NativeErrors"].Length, "physical retirement must acknowledge every native resource")
		AssertFalse(_SR_TreeOwnedTasks.Has(State["TaskId"]), "the completed admission cannot retain an active native task")
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "the completed admission cannot retain capture cleanup debt")
		AssertFalse(FileExist(Claim["TmpFile"]), "the actual capture file must be retired")
		AssertFalse(DirExist(Claim["CaptureDir"]), "the actual capture directory must be retired")
	} finally {
		if IsObject(Handle) {
			Acknowledged := Handle.terminate()
			if !Acknowledged {
				AssertTrue(Control.Has("state"), "an unacknowledged task cannot lose its cleanup owner")
				State := Control["state"]
				AssertTrue(State["TreeQuiesced"] && !State["FinalizationPending"],
					"an already completed task must retain its physical retirement receipt")
			}
		}
	}
}
Test("Driver control CLI: actual Windows session admission requires native PowerShell (control-cli-native-session)",
	_DCCLI_NativeAdmission.Bind("session"))

Test("Driver control CLI: actual Windows result admission requires native PowerShell (control-cli-native-result)",
	_DCCLI_NativeAdmission.Bind("result"))
