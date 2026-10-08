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
	Cause := _SystemProxy_RetirementCauseFact(Out, Fact[1], Fact[2])
	if Cause != ""
		_TestPrint("::notice title=Windows legacy PAC closed cause::" . Cause)
	_TestPrint("::notice title=Windows legacy PAC retirement::" . SubStr(Fact[0], StrLen("RETIREMENT_DIAG ")+1))
}

; A child notice remains captured until this settled owner validates its closed fields.
_SystemProxy_RetirementCauseFact(Out, Control, Stage) {
	if !(Out is String) || StrLen(Out) > 8192
		return ""
	Pattern := "m)^::notice title=Windows legacy PAC closed cause::control=([0-5]) stage=(prepare|prepare_control|start_child|child_exit|process_receipt|frame_parse|call_count|frame_contract|raw_proxy_contract) cause=(other|get_file_hash_command_missing|optional_control_property_missing|source_identity_mismatch) line=(0|[1-9][0-9]{0,3})`r?$"
	if !RegExMatch(Out, Pattern, &Fact)
		return ""
	if RegExMatch(Out, Pattern, , Fact.Pos + Fact.Len)
		return ""
	if Fact[1] != Control || Fact[2] != Stage || Integer(Fact[4]) > 4096
		return ""
	return "control=" . Fact[1] . " stage=" . Fact[2] . " cause=" . Fact[3] . " line=" . Fact[4]
}

_SystemProxy_RetirementCauseProjectionControls() {
	Prefix := "::notice title=Windows legacy PAC closed cause::"
	Fields := "control=1 stage=prepare_control cause=get_file_hash_command_missing line=55"
	AssertEqual(Fields, _SystemProxy_RetirementCauseFact(Prefix . Fields . "`n", "1", "prepare_control"))
	AssertEqual(Fields, _SystemProxy_RetirementCauseFact(Prefix . Fields . "`r`n", "1", "prepare_control"))
	for Cause in ["other", "optional_control_property_missing", "source_identity_mismatch"] {
		Value := "control=1 stage=prepare_control cause=" . Cause . " line=0"
		AssertEqual(Value, _SystemProxy_RetirementCauseFact(Prefix . Value, "1", "prepare_control"))
	}
	for Value in [Prefix . Fields . "`n" . Prefix . Fields,
		Prefix . StrReplace(Fields, "control=1", "control=2"),
		Prefix . StrReplace(Fields, "control=1", "control=6"),
		Prefix . StrReplace(Fields, "control=1", "control=01"),
		Prefix . StrReplace(Fields, "prepare_control", "frame_parse"),
		Prefix . StrReplace(Fields, "prepare_control", "unadmitted"),
		Prefix . StrReplace(Fields, "get_file_hash_command_missing", "raw_error"),
		Prefix . StrReplace(Fields, "line=55", "line=4097"),
		Prefix . StrReplace(Fields, "line=55", "line=0055"),
		Prefix . StrReplace(Fields, "line=55", "line=-1"),
		Prefix . Fields . " extra=value", "arbitrary " . Prefix . Fields] {
		AssertEqual("", _SystemProxy_RetirementCauseFact(Value, "1", "prepare_control"),
			"unadmitted or mismatched captured causes must remain private")
	}
	AssertEqual("", _SystemProxy_RetirementCauseFact(Map(), "1", "prepare_control"))
	AssertEqual("", _SystemProxy_RetirementCauseFact(Prefix . Fields . StrReplace(Format("{:8193}", ""), " ", "x"), "1", "prepare_control"))
	Boundary := StrReplace(Fields, "line=55", "line=4096")
	AssertEqual(Boundary, _SystemProxy_RetirementCauseFact(Prefix . Boundary, "1", "prepare_control"))
}
Test("managed network: closed legacy cause projection refuses foreign, duplicate and unbounded receipts", _SystemProxy_RetirementCauseProjectionControls)
