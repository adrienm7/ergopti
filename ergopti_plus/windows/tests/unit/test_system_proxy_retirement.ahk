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
	Raw := _SystemProxy_RetirementRawFlagsFact(Observation.Get("stdout", ""))
	if Raw != ""
		_TestPrint("::notice title=Windows legacy PAC raw contract::" . Raw)
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

; Tree completion merges both streams into the same settled stdout capture.
_SystemProxy_RetirementRawFlagsFact(Err) {
	if !(Err is String) || StrLen(Err) > 8192
		return ""
	Diagnostic := "m)^RETIREMENT_DIAG control=5 stage=raw_proxy_contract child_exit=0 stdout_units=(0|[1-9][0-9]{0,3}) stderr_units=0`r?$"
	if !RegExMatch(Err, Diagnostic, &Owner) || Integer(Owner[1]) > 8192
		return ""
	FirstOwner := InStr(Err, "RETIREMENT_DIAG")
	if InStr(Err, "RETIREMENT_DIAG", , FirstOwner + 1)
		return ""
	Pattern := "m)^RETIREMENT_RAW_FLAGS control=5 schema=1 ok_bool=([01]) ok_true=([01]) kind_text=([01]) kind_named=([01]) access_integer=([01]) access_three=([01]) proxy_text=([01]) proxy_literal=([01]) proxy_legacy_ipv6_literal=([01]) bypass_text=([01]) bypass_empty=([01]) native_integer=([01]) native_zero=([01])(?: proxy_ipv6_bracket=([01]) proxy_ipv6_authority=([01]) proxy_ipv6_port=([01]) proxy_ipv6_normalized_literal=([01]))?`r?$"
	if !RegExMatch(Err, Pattern, &Fact)
		return ""
	FirstRaw := InStr(Err, "RETIREMENT_RAW_FLAGS")
	if InStr(Err, "RETIREMENT_RAW_FLAGS", , FirstRaw + 1)
		return ""
	return RTrim(SubStr(Fact[0], StrLen("RETIREMENT_RAW_FLAGS ") + 1), "`r")
}

_SystemProxy_RetirementRawProjectionControls() {
	Owner := "RETIREMENT_DIAG control=5 stage=raw_proxy_contract child_exit=0 stdout_units=200 stderr_units=0"
	Fields := "control=5 schema=1 ok_bool=1 ok_true=1 kind_text=1 kind_named=1 access_integer=1 access_three=1 proxy_text=1 proxy_literal=0 proxy_legacy_ipv6_literal=1 bypass_text=1 bypass_empty=1 native_integer=1 native_zero=1"
	Raw := "RETIREMENT_RAW_FLAGS " . Fields
	AssertEqual(Fields, _SystemProxy_RetirementRawFlagsFact(Owner . "`n" . Raw . "`n"))
	AssertEqual(Fields, _SystemProxy_RetirementRawFlagsFact(Owner . "`r`n" . Raw . "`r`n"))
	for Name in ["ok_bool", "ok_true", "kind_text", "kind_named", "access_integer", "access_three",
		"proxy_text", "proxy_literal", "proxy_legacy_ipv6_literal", "bypass_text", "bypass_empty", "native_integer", "native_zero"] {
		Value := RegExReplace(Fields, "\b" . Name . "=[01]", Name . "=0")
		AssertEqual(Value, _SystemProxy_RetirementRawFlagsFact(Owner . "`nRETIREMENT_RAW_FLAGS " . Value))
	}
	for Value in [Raw, Owner, Owner . "`n" . Raw . "`n" . Raw,
		Owner . "`n" . Raw . "`nRETIREMENT_RAW_FLAGS malformed",
		Owner . "`n" . Raw . "`nRETIREMENT_DIAG malformed",
		StrReplace(Owner, "control=5", "control=4") . "`n" . Raw,
		StrReplace(Owner, "raw_proxy_contract", "frame_contract") . "`n" . Raw,
		StrReplace(Owner, "child_exit=0", "child_exit=1") . "`n" . Raw,
		StrReplace(Owner, "stdout_units=200", "stdout_units=8193") . "`n" . Raw,
		StrReplace(Owner, "stderr_units=0", "stderr_units=1") . "`n" . Raw,
		Owner . "`n" . StrReplace(Raw, "control=5", "control=4"),
		Owner . "`n" . StrReplace(Raw, "schema=1", "schema=2"),
		Owner . "`n" . StrReplace(Raw, "ok_bool=1", "ok_bool=true"),
		Owner . "`n" . StrReplace(Raw, "ok_bool=1", "ok_bool=2"),
		Owner . "`n" . StrReplace(Raw, "proxy_literal=0", "proxy_literal=PRIVATE"),
		Owner . "`n" . Raw . " extra=PRIVATE", Owner . "`nforeign " . Raw] {
		AssertEqual("", _SystemProxy_RetirementRawFlagsFact(Value), "only one same-owner closed boolean receipt may be projected")
	}
	AssertEqual("", _SystemProxy_RetirementRawFlagsFact(Map()))
	AssertEqual("", _SystemProxy_RetirementRawFlagsFact(Owner . "`n" . Raw . StrReplace(Format("{:8193}", ""), " ", "x")))
}
Test("managed network: raw legacy contract projection requires same settled stderr owner and bounded booleans", _SystemProxy_RetirementRawProjectionControls)


_SystemProxy_RetirementMergedCaptureControls() {
	Owner := "RETIREMENT_DIAG control=5 stage=raw_proxy_contract child_exit=0 stdout_units=200 stderr_units=0"
	Fields := "control=5 schema=1 ok_bool=1 ok_true=1 kind_text=1 kind_named=1 access_integer=1 access_three=1 proxy_text=1 proxy_literal=0 proxy_legacy_ipv6_literal=1 bypass_text=1 bypass_empty=1 native_integer=1 native_zero=1"
	Details := " proxy_ipv6_bracket=1 proxy_ipv6_authority=1 proxy_ipv6_port=1 proxy_ipv6_normalized_literal=1"
	Raw := "RETIREMENT_RAW_FLAGS " . Fields . Details
	Capture := Raw . "`r`n" . Owner . "`r`nLegacy proxy retirement protocol failed.`r`n"
	AssertEqual(Fields . Details, _SystemProxy_RetirementRawFlagsFact(Capture), "facts may precede the primary assertion in the exact merged capture")
	for Value in [StrReplace(Capture, "proxy_ipv6_bracket=1", "proxy_ipv6_bracket=PRIVATE"),
		StrReplace(Capture, "proxy_ipv6_port=1", "proxy_ipv6_port=2"),
		StrReplace(Capture, " proxy_ipv6_normalized_literal=1", ""),
		Capture . Raw, Capture . "RETIREMENT_DIAG malformed"]
		AssertEqual("", _SystemProxy_RetirementRawFlagsFact(Value), "partial or foreign authority facts remain private")
}
Test("managed network: settled merged capture admits only closed IPv6 authority flags", _SystemProxy_RetirementMergedCaptureControls)
