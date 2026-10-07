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
		; Optional sink failure cannot replace any original assertion.
		if Observed[1]["exit"] != 0 {
			try _ManagedRoutes_NativeDiagnostic(Observed[1])
		}
		AssertEqual(0, Observed[1]["exit"], "the canonical native routing entrypoint must qualify")
		AssertEqual("", Observed[1]["stderr"], "native errors and cleanup refusals must remain red")
		AssertContains(Observed[1]["stdout"], "[OK] production routing helper:")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact owned native fixture tree must physically retire")
	}
}
Test("managed network: real canonical WinHTTP Ex preserves full PAC order and fresh bytes", _ManagedRoutes_NativeAcceptance)

; Emit only a closed diagnostic from the already-settled exact child. Raw stderr
; remains subject to the original failure assertion and is never forwarded here.
_ManagedRoutes_NativeDiagnostic(Observation) {
	Err := Observation.Get("stderr", "")
	if !(Err is String) || StrLen(Err) > 8192
		return
	Pattern := "m)^ROUTE_DIAG stage=(load_routes|abi_sizes|compile_server|start_server|vector_lookup|vector_receipt|vector_order|fresh_lookup|fresh_order|unsupported_lookup|unsupported_receipt|settings_read|settings_receipt|server_receipt|cleanup)"
		. " vector=([0-3]) native_observed=([01]) native_errno=(-?(?:0|[1-9][0-9]{0,9}))"
		. " status=(unknown|unavailable|invalid_configuration|pac_failed|wpad_failed)`r?$"
	if !RegExMatch(Err, Pattern, &Fact)
		return
	; Refuse duplicate observations rather than choosing a later failure frame.
	if RegExMatch(Err, Pattern, , Fact.Pos + Fact.Len)
		return
	if Integer(Fact[4]) < -2147483648 || Integer(Fact[4]) > 2147483647
		return
	if Fact[3] == "0" && Fact[4] != "0"
		return
	FileAppend("::notice title=Windows native route diagnostic::stage=" . Fact[1] . " vector=" . Fact[2]
		. " native_observed=" . Fact[3] . " native_errno=" . Fact[4]
		. " status=" . Fact[5] . "`n", "*")
}
