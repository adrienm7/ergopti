; tests/unit/test_network_pac_source_contract.ahk
; The real Windows tick, HTTP fetch and deadline owners remain mandatory.
_NetworkPAC_SourceContractAcceptance() {
	global _VendorDir, _DriverDir, _SharedDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\pac_source_contract.ps1", "-WorkerPath",
				_VendorDir . "\ergopti_network_pac.ps1", "-PolicyPath",
				_SharedDir . "\modules\network\proxy_policy.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "the production-source PAC contract fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 55000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the exact PAC source owner must settle before its original test deadline")
		if Observed.Length != 1
			return
		AssertEqual(0, Observed[1]["exit"], "real source/credential/body refusals must preserve the production contract")
		AssertEqual("", Observed[1]["stderr"], "source decode and physical native retirement refusals remain red")
		AssertContains(Observed[1]["stdout"], "PAC_SOURCE_NATIVE controls=44 owners_retired=true")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact private PAC fixture tree must physically retire")
	}
}
Test("managed PAC source: real bounded source acquisition and initial-authority credentials", _NetworkPAC_SourceContractAcceptance)
