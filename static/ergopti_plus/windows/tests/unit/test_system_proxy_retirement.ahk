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
		AssertEqual(0, Observed[1]["exit"], "native owner debt must refuse all later legacy lookups and partial receipts")
		AssertEqual("", Observed[1]["stderr"], "protocol errors and physical cleanup refusals must remain red")
		AssertContains(Observed[1]["stdout"], "[OK] legacy proxy protocol:")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact owned protocol fixture tree must physically retire")
	}
}
Test("managed network: legacy native-owner debt stops subsequent lookups and partial receipts", _SystemProxy_RetirementProtocolAcceptance)
