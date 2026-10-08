; tests/unit/test_system_proxy_retirement.ahk
; Native ports are controlled here; actual PAC and SSPI have separate acceptance.
_SystemProxy_RetirementProtocolAcceptance() {
	global _VendorDir, _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\system_proxy_retirement.ps1", "-WorkerPath",
				_VendorDir . "\ergopti_system_proxy_worker.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "the owned source-executed protocol fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 55000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the exact protocol fixture must settle within its test budget")
		if Observed[1]["exit"] != 0
			try _SystemProxy_RetirementDiagnostic(Observed[1])
		AssertEqual(0, Observed[1]["exit"], "native owner debt must refuse all later legacy lookups and partial receipts")
		AssertEqual("", Observed[1]["stderr"], "protocol errors and physical cleanup refusals must remain red")
		AssertContains(Observed[1]["stdout"], "[OK] legacy proxy protocol:")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact owned protocol fixture tree must physically retire")
	}
}
Test("managed network: legacy native-owner debt stops subsequent lookups and partial receipts", _SystemProxy_RetirementProtocolAcceptance)

; Project only enumerated stages and bounded scalars from the settled owner capture.
_SystemProxy_RetirementDiagnostic(Observation) {
	Out := Observation.Get("stdout", "")
	if !(Out is String) || StrLen(Out) > 8192
		return
	Pattern := "m)^RETIREMENT_DIAG control=([0-5]) stage=(prepare|prepare_control|start_child|child_exit|process_receipt|frame_parse|call_count|frame_contract|raw_proxy_contract) child_exit=(-999|-?(?:0|[1-9][0-9]{0,9})) stdout_units=(-1|0|[1-9][0-9]{0,3}) stderr_units=(-1|0|[1-9][0-9]{0,3})`r?$"
	if !RegExMatch(Out, Pattern, &Fact)
		return
	if RegExMatch(Out, Pattern, , Fact.Pos + Fact.Len)
		return
	if Integer(Fact[3]) < -2147483648 || Integer(Fact[3]) > 2147483647
		return
	if Integer(Fact[4]) > 8192 || Integer(Fact[5]) > 8192
		return
	_TestPrint("::notice title=Windows legacy PAC retirement::" . SubStr(Fact[0], StrLen("RETIREMENT_DIAG ")+1))
}
