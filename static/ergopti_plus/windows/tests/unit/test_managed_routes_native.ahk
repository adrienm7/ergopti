; tests/unit/test_managed_routes_native.ahk
; Real canonical route entrypoint and native PAC/settings qualification.
_ManagedRoutes_NativeAcceptance() {
	global _VendorDir, _DriverDir, _SharedDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\managed_routes_native.ps1", "-RoutesPath",
				_VendorDir . "\ergopti_network_routes.ps1", "-PolicyPath",
				_SharedDir . "\modules\network\proxy_policy.json", "-UpdaterDefaultsPath",
				_SharedDir . "\modules\updater\defaults.json"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "the real native complete-route fixture must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 55000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the exact native fixture must settle within its total test budget")
		AssertEqual(0, Observed[1]["exit"], "the canonical native routing entrypoint must qualify")
		AssertEqual("", Observed[1]["stderr"], "native errors and cleanup refusals must remain red")
		AssertContains(Observed[1]["stdout"], "[OK] production routing helper:")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact owned native fixture tree must physically retire")
	}
}
Test("managed network: real canonical WinHTTP Ex preserves full PAC order and fresh bytes", _ManagedRoutes_NativeAcceptance)
