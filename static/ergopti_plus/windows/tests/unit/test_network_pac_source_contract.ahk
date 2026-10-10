; tests/unit/test_network_pac_source_contract.ahk
; The real Windows tick, HTTP fetch and deadline owners remain mandatory.
; Projects only closed classifications from the already settled private capture.
_NetworkPAC_SourceFailureSummary(Stderr) {
	if !(Stderr is String) || StrLen(Stderr) > 8192
		return "kind=invalid_capture line=0 cs=none"
	RecordClass := ""
	RecordLine := 0
	RecordPattern := "m)^PAC_SOURCE_ERROR exception=(unknown|MethodException|MethodInvocationException|RuntimeException|TargetInvocationException|TargetParameterCountException|MissingMethodException|ArgumentException|ArgumentNullException|ArgumentOutOfRangeException|InvalidOperationException|InvalidDataException|DecoderFallbackException|FileNotFoundException|DirectoryNotFoundException|IOException|UnauthorizedAccessException|TimeoutException|WebException|ObjectDisposedException|PacOwnerDebtException|TypeInitializationException|NotSupportedException|PlatformNotSupportedException|Win32Exception) line=(0|[1-9][0-9]{0,3})`r?$"
	if RegExMatch(Stderr, RecordPattern, &RecordFact)
		&& InStr(Stderr, "PAC_SOURCE_ERROR", true) == RecordFact.Pos
		&& !InStr(Stderr, "PAC_SOURCE_ERROR", true, RecordFact.Pos + StrLen("PAC_SOURCE_ERROR"))
		&& Integer(RecordFact[2]) <= 4095 {
		RecordClass := RecordFact[1]
		RecordLine := Integer(RecordFact[2])
	}
	Kind := "unknown"
	Codes := Map()
	Offset := 1
	while RegExMatch(Stderr, "i)\berror\s+CS([0-9]{4})\s*:", &Match, Offset) {
		Codes[Match[1]] := true
		Offset := Match.Pos + Match.Len
	}
	if Codes.Count > 0
		Kind := "compiler_error"
	else if RegExMatch(Stderr, "\b(?:ParserError|ParseException)\b")
		Kind := "parser_error"
	else if RegExMatch(Stderr, "\b(?:FileNotFoundException|DirectoryNotFoundException|PathNotFound)\b")
		Kind := "file_missing"
	else if InStr(Stderr, "TargetParameterCountException") || InStr(Stderr, "Parameter count mismatch.")
		Kind := "method_arity"
	else if RegExMatch(Stderr, "\b(?:MethodException|MethodInvocationException|MissingMethodException)\b")
		Kind := "method_binding"
	else if InStr(Stderr, "Production source policy mutation did not refuse before acquisition.")
		|| InStr(Stderr, "Production missing source policy field did not refuse before acquisition.")
		|| InStr(Stderr, "Production JSON array source field did not refuse before acquisition.")
		Kind := "policy_refusal"
	else if InStr(Stderr, "Native credential authority tuple differs.")
		|| InStr(Stderr, "Initial authority lost native default credentials.")
		|| InStr(Stderr, "Foreign authority acquired native default credentials.")
		Kind := "credential_scope"
	else if InStr(Stderr, "Real source fetch did not preserve the complete script.")
		|| InStr(Stderr, "Real malformed/non200/oversized source was admitted.")
		Kind := "source_body"
	else if InStr(Stderr, "Production source deadline owner remains physically unsettled.")
		|| InStr(Stderr, "Owned PAC peer did not retire")
		Kind := "owner_debt"
	Lines := Map()
	Offset := 1
	while RegExMatch(Stderr, "im)^At [^\r\n]*[\\/]pac_source_contract\.ps1:([0-9]{1,4}) char:[0-9]+\r?$", &Match, Offset) {
		Line := Integer(Match[1])
		if Line >= 1 && Line <= 4095
			Lines[Line] := true
		Offset := Match.Pos + Match.Len
	}
	Line := 0
	if Lines.Count == 1
		for Candidate, _ in Lines
			Line := Candidate
	Code := Codes.Count > 1 ? "multiple" : "none"
	if Codes.Count == 1
		for Candidate, _ in Codes
			Code := "CS" . Candidate
	if RecordClass != ""
		Line := RecordLine
	return "kind=" . Kind . " line=" . Line . " cs=" . Code
		. (RecordClass == "" ? "" : " exception=" . RecordClass)
}

; The settled tree owner combines both native streams in stdout.
_NetworkPAC_SourceObservationFailureSummary(Observation) {
	return _NetworkPAC_SourceFailureSummary(Observation["stdout"])
}

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
		AssertEqual(0, Observed[1]["exit"], "real source/credential/body refusals must preserve the production contract"
			. (Observed[1]["exit"] == 0 ? "" : " [" . _NetworkPAC_SourceObservationFailureSummary(Observed[1]) . "]"))
		AssertEqual("", Observed[1]["stderr"], "source decode and physical native retirement refusals remain red")
		AssertContains(Observed[1]["stdout"], "PAC_SOURCE_NATIVE controls=44 owners_retired=true")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact private PAC fixture tree must physically retire")
	}
}
Test("managed PAC source: real bounded source acquisition and initial-authority credentials", _NetworkPAC_SourceContractAcceptance)

_NetworkPAC_SourceFailureDiagnosticCompiler() {
	ErrorText := "Add-Type : error CS0103: controlled compiler refusal`n"
		. "At C:\private\pac_source_contract.ps1:8 char:1`n"
		. "secret=diagnostic-private-sentinel"
	AssertEqual("kind=compiler_error line=8 cs=CS0103", _NetworkPAC_SourceFailureSummary(ErrorText))
	AssertFalse(InStr(_NetworkPAC_SourceFailureSummary(ErrorText), "diagnostic-private-sentinel"),
		"private compiler content must never enter the closed projection")
	AssertEqual("kind=compiler_error line=8 cs=multiple",
		_NetworkPAC_SourceFailureSummary(ErrorText . "`nerror CS0246: another refusal"))
}
Test("managed PAC source: compiler failure diagnostics retain only closed scalars", _NetworkPAC_SourceFailureDiagnosticCompiler)

_NetworkPAC_SourceFailureDiagnosticCategories() {
	for ErrorText, Expected in Map(
		"ParserError", "parser_error",
		"FileNotFoundException", "file_missing",
		"Parameter count mismatch.", "method_arity",
		"MethodInvocationException", "method_binding",
		"Production missing source policy field did not refuse before acquisition.", "policy_refusal",
		"Initial authority lost native default credentials.", "credential_scope",
		"Real source fetch did not preserve the complete script.", "source_body",
		"Owned PAC peer did not retire", "owner_debt") {
		AssertEqual("kind=" . Expected . " line=0 cs=none", _NetworkPAC_SourceFailureSummary(ErrorText))
	}
}
Test("managed PAC source: failure classifications preserve their closed inventory", _NetworkPAC_SourceFailureDiagnosticCategories)

_NetworkPAC_SourceFailureDiagnosticRefusals() {
	Oversized := ""
	loop 8193
		Oversized .= "x"
	AssertEqual("kind=unknown line=0 cs=none", _NetworkPAC_SourceFailureSummary("private arbitrary exception"))
	AssertEqual("kind=invalid_capture line=0 cs=none", _NetworkPAC_SourceFailureSummary(Map()))
	AssertEqual("kind=invalid_capture line=0 cs=none", _NetworkPAC_SourceFailureSummary(Oversized))
	AssertEqual("kind=unknown line=0 cs=none",
		_NetworkPAC_SourceFailureSummary("At C:\private\pac_source_contract.ps1:8 char:1`nAt C:\private\pac_source_contract.ps1:30 char:1"))
	AssertEqual("kind=unknown line=0 cs=none", _NetworkPAC_SourceFailureSummary("At C:\private\pac_source_contract.ps1:9999 char:1"))
	AssertEqual("kind=unknown line=0 cs=none", _NetworkPAC_SourceFailureSummary("pac_source_contract.ps1:8 char:1"))
	AssertEqual("kind=unknown line=0 cs=none",
		_NetworkPAC_SourceFailureSummary("At C:\private\pac_source_contract.ps1:8 char:1 private"))
	AssertEqual("kind=unknown line=8 cs=none",
		_NetworkPAC_SourceFailureSummary("At C:\private\pac_source_contract.ps1:8 char:1`nAt C:\private\pac_source_contract.ps1:8 char:1"))
}
Test("managed PAC source: invalid and ambiguous diagnostics never expose private capture", _NetworkPAC_SourceFailureDiagnosticRefusals)

_NetworkPAC_SourceFailureDiagnosticOwnedCapture() {
	Observed := []
	Handle := 0
	Command := "$ErrorActionPreference = 'Stop'; throw 'Production source policy mutation did not refuse before acquisition.'"
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", Command],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start(), "the genuine native diagnostic error child must start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 55000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "the exact diagnostic error owner must settle once within its original caller bound")
		if Observed.Length != 1
			return
		AssertEqual(1, Observed[1]["exit"], "the fixed native policy exception must remain a failure")
		AssertTrue(Observed[1]["stdout"] is String && StrLen(Observed[1]["stdout"]) > 0,
			"the settled native owner must retain its nonempty combined output")
		AssertTrue(Observed[1]["stderr"] == "", "the tree owner keeps its separate stderr slot empty")
		AssertEqual("kind=unknown line=0 cs=none", _NetworkPAC_SourceFailureSummary(Observed[1]["stderr"]),
			"the former stderr projection cannot diagnose this genuine captured failure")
		AssertEqual("kind=policy_refusal line=0 cs=none", _NetworkPAC_SourceObservationFailureSummary(Observed[1]),
			"the same Source44 selector must classify the genuine combined error capture")
	} finally {
		AssertTrue(IsObject(Handle) ? Handle.terminate() : true, "the exact diagnostic error tree must physically retire")
	}
}
Test("managed PAC source: owned native error capture feeds the closed diagnostic", _NetworkPAC_SourceFailureDiagnosticOwnedCapture)

_NetworkPAC_SourceFailureDiagnosticErrorRecord() {
	Frame := "PAC_SOURCE_ERROR exception=TargetParameterCountException line=183"
	AssertEqual("kind=method_arity line=183 cs=none exception=TargetParameterCountException", _NetworkPAC_SourceFailureSummary(Frame))
	AssertEqual("kind=unknown line=0 cs=none exception=unknown", _NetworkPAC_SourceFailureSummary("PAC_SOURCE_ERROR exception=unknown line=0"))
	for Invalid in [Frame . "`n" . Frame,
		Frame . "`nPAC_SOURCE_ERROR exception=diagnostic-private-sentinel line=1",
		"PAC_SOURCE_ERROR exception=TargetParameterCountException line=4096",
		"PAC_SOURCE_ERROR exception=TargetParameterCountException line=-1",
		"PAC_SOURCE_ERROR exception=TargetParameterCountException line=01",
		Frame . " private=diagnostic-private-sentinel"]
		AssertEqual("kind=method_arity line=0 cs=none", _NetworkPAC_SourceFailureSummary(Invalid))
	AssertEqual("kind=unknown line=0 cs=none", _NetworkPAC_SourceFailureSummary("PAC_SOURCE_ERROR exception=diagnostic-private-sentinel line=183"))
}
Test("managed PAC source: original ErrorRecord diagnostics admit only closed unique facts", _NetworkPAC_SourceFailureDiagnosticErrorRecord)
