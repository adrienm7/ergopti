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
			try _ManagedRoutes_NativeUrlDiagnostic(Observed[1])
			try _ManagedRoutes_NativeAuthDiagnostic(Observed[1])
		}
		AssertEqual(0, Observed[1]["exit"], "the canonical native routing entrypoint must qualify")
		AssertEqual("", Observed[1]["stderr"], "native errors and cleanup refusals must remain red")
		AssertContains(Observed[1]["stdout"], "[OK] production routing helper:")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact owned native fixture tree must physically retire")
	}
}
Test("managed network: real canonical native PAC preserves full URL, order, fresh bytes and current-user SSPI", _ManagedRoutes_NativeAcceptance)

; The original owner combines both native streams in its stdout callback value.
; Emit only the closed frame from that already-settled capture; never raw output.
_ManagedRoutes_NativeDiagnostic(Observation) {
	Err := Observation.Get("stdout", "")
	if !(Err is String) || StrLen(Err) > 8192
		return
	Pattern := "m)^ROUTE_DIAG stage=(load_routes|abi_sizes|compile_server|start_server|vector_lookup|vector_receipt|vector_order|fresh_lookup|fresh_order|unsupported_lookup|unsupported_receipt|slow_lookup|slow_receipt|slow_owner|pac_auth_lookup|pac_auth_receipt|pac_auth_owner|settings_read|settings_receipt|server_receipt|cleanup)"
		. " vector=([0-3]) native_observed=([01]) native_errno=(-?(?:0|[1-9][0-9]{0,9}))"
		. " status=(unknown|unavailable|invalid_configuration|pac_failed|wpad_failed)"
		. " result_shape=(unknown|null|hashtable|array|other) ok=(unknown|true|false)"
		. " route_count=(-1|0|[1-9][0-9]{0,3}) limits=(unknown|match|mismatch)"
		. " single_source=(unknown|loopback|environment|environment_bypass|system_direct|system_bypass|system_config_absent_direct|system_config_absent_bypass|system_proxy|system_config_absent_proxy|wpad_absent_direct|wpad_absent_bypass|wpad_absent_proxy|native_proxy|native_direct|native_bypass)"
		. " single_kind=(unknown|direct|proxy)`r?$"
	if !RegExMatch(Err, Pattern, &Fact)
		return
	; Refuse duplicate observations rather than choosing a later failure frame.
	if RegExMatch(Err, Pattern, , Fact.Pos + Fact.Len)
		return
	if Integer(Fact[4]) < -2147483648 || Integer(Fact[4]) > 2147483647
		return
	if Fact[3] == "0" && Fact[4] != "0"
		return
	if Integer(Fact[8]) < -1 || Integer(Fact[8]) > 4096
		return
	if Fact[6] != "hashtable" && (Fact[7] != "unknown" || Fact[8] != "-1" || Fact[9] != "unknown")
		return
	if Fact[8] != "1" && (Fact[10] != "unknown" || Fact[11] != "unknown")
		return
	FileAppend("::notice title=Windows native route diagnostic::stage=" . Fact[1] . " vector=" . Fact[2]
		. " native_observed=" . Fact[3] . " native_errno=" . Fact[4]
		. " status=" . Fact[5] . " result_shape=" . Fact[6] . " ok=" . Fact[7]
		. " route_count=" . Fact[8] . " limits=" . Fact[9]
		. " single_source=" . Fact[10] . " single_kind=" . Fact[11] . "`n", "*")
}

; Native PAC branches return only fixed fixture identities, never captured URLs.
_ManagedRoutes_NativeUrlDiagnostic(Observation) {
	Out := Observation.Get("stdout", "")
	if !(Out is String) || StrLen(Out) > 8192
		return
	Pattern := "m)^ROUTE_URL_DIAG shape=(unavailable|full|path|origin|scheme|other)`r?$"
	if !RegExMatch(Out, Pattern, &Fact)
		return
	if RegExMatch(Out, Pattern, , Fact.Pos + Fact.Len)
		return
	_TestPrint("::notice title=Windows native PAC URL shape::shape=" . Fact[1])
}

; Project only enumerated stages and bounded scalars from the settled owner capture.
_ManagedRoutes_NativeAuthDiagnostic(Observation) {
	Out := Observation.Get("stdout", "")
	if !(Out is String) || StrLen(Out) > 8192
		return
	Pattern := "m)^PAC_AUTH_DIAG stage=(none|acquire_credentials|accept_context|context_token|identity_match|other) security_status=(-?(?:0|[1-9][0-9]{0,9})) identity=([01]) bare=([0-9]{1,3}) type_one=([0-9]{1,3}) type_three=([0-9]{1,3}) authenticated=([0-9]{1,3}) responses=([0-9]{1,3}) failures=([0-9]{1,3}) active=([0-9]{1,3}) credentials=([0-9]{1,3}) contexts=([0-9]{1,3}) tokens=([0-9]{1,3}) buffers=([0-9]{1,3})`r?$"
	if !RegExMatch(Out, Pattern, &Fact)
		return
	if RegExMatch(Out, Pattern, , Fact.Pos + Fact.Len)
		return
	if Integer(Fact[2]) < -2147483648 || Integer(Fact[2]) > 2147483647
		return
	loop 11 {
		if Integer(Fact[A_Index + 3]) > 256
			return
	}
	_TestPrint("::notice title=Windows PAC origin authentication::" . SubStr(Fact[0], StrLen("PAC_AUTH_DIAG ")+1))
}
