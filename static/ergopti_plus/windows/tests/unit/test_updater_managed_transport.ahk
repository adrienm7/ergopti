; tests/unit/test_updater_managed_transport.ahk
; Actual generated staging orchestrator over owned native TLS/PAC/CONNECT.
; Trusted readers and passive fixture-only staging observations are declared seams.

_UpdaterNativeRefusalWebStatus(Receipt) {
	global _UpdaterManagedFailureContract
	Value := Receipt.Get("dotnet_web_status", "")
	if !(Value is String) || !HasProp(_UpdaterManagedFailureContract, "Policy")
		return "unknown"
	Definition := _UpdaterManagedFailureContract.Policy["fields"].Get("dotnet_web_status", 0)
	if !(Definition is Map) || !(Definition.Get("values", 0) is Array)
		return "unknown"
	for Allowed in Definition["values"]
		if StrCompare(Value, Allowed, true) == 0
			return Value
	return "unknown"
}

_UpdaterNativeRefusalDiagnostic(ExpectedStage, Receipt) {
	Receipt := Receipt is Map ? Receipt : Map()
	StagePattern := "proxy_resolve|proxy_connect|connect|tls|http|file_read|file_write|file_create|file_rename|file_remove"
	Fact := "expected_stage=" . _ManagedRemoteFixtureDiagnosticEnum(ExpectedStage, StagePattern)
		. " observed_stage=" . _ManagedRemoteFixtureDiagnosticEnum(Receipt.Get("stage", ""), StagePattern)
		. " backend=" . _ManagedRemoteFixtureDiagnosticEnum(Receipt.Get("backend", ""),
			"curl|winhttp|wininet|dotnet|urlsession|gio|native_fs|native_socket")
	for Pair in [["curl_exit", 255], ["http_status", 599], ["proxy_connect_status", 599]] {
		Value := Receipt.Get(Pair[1], "")
		Fact .= " " . Pair[1] . "=" . (Type(Value) == "Integer" && Value >= 0 && Value <= Pair[2]
			? Format("{:d}", Value) : "unknown")
	}
	NativeCode := "unknown"
	RawCode := Receipt.Get("native_errno", "")
	if RawCode is String && RegExMatch(RawCode, "\A-?(?:0|[1-9][0-9]{0,9})\z") {
		Value := Integer(RawCode)
		if Value >= -2147483648 && Value <= 2147483647
			NativeCode := Format("{:d}", Value)
	}
	return Fact . " proxy_mode=" . _ManagedRemoteFixtureDiagnosticEnum(Receipt.Get("proxy_mode", ""),
		"selected|direct|environment|unavailable")
		. " native_errno_domain=" . _ManagedRemoteFixtureDiagnosticEnum(Receipt.Get("native_errno_domain", ""), "posix|win32|winsock")
		. " native_errno=" . NativeCode . " tls_status=" . _ManagedRemoteFixtureDiagnosticEnum(Receipt.Get("tls_status", ""),
			"untrusted_certificate|expired_certificate|hostname_mismatch|revoked_certificate|unavailable")
		. " dotnet_web_status=" . _UpdaterNativeRefusalWebStatus(Receipt)
}

; The shared failure schema stays unchanged; this private sidecar is observation only.
_UpdaterNativeObservedStagingScript(OriginalScript) {
	global _DriverDir
	Helper := FileRead(_DriverDir . "\tests\fixtures\updater_staging_diagnostic.ps1", "UTF-8")
	HeaderEnd := InStr(OriginalScript, "`n")
	if !HeaderEnd
		throw Error("The actual staging parameter declaration is unavailable.")
	; A literal here-string avoids redundant Base64 expansion of trusted source.
	; A closing delimiter cannot escape into the surrounding fixture worker.
	if RegExMatch(OriginalScript, "(?:\A|[\r\n])'@")
		throw Error("The staging fixture source contains a literal delimiter.")
	return SubStr(OriginalScript, 1, HeaderEnd) . Helper . "`n"
		. "$StagingSource=@'`n" . OriginalScript . "`n'@`n"
		. '$StagingObserved=New-ErgoptiObservedStagingScript $StagingSource ""' . "`n"
		. '& ([scriptblock]::Create($StagingObserved.Source)) @PSBoundParameters'
}

_UpdaterNativeStagingScalarFact(Scalar) {
	if !(Scalar is Map) || Scalar.Count < 3 || Scalar.Count > 4
		return ""
	for DiagnosticKey in Scalar
		if !(DiagnosticKey is String) || !RegExMatch(DiagnosticKey, "\A(?:type|arity|size_available|size)\z")
			return ""
	DiagnosticType := Scalar.Get("type", "")
	DiagnosticArity := Scalar.Get("arity", -2)
	DiagnosticAvailability := Scalar.Get("size_available", "")
	if !(DiagnosticType is String) || !RegExMatch(DiagnosticType, "\A(?:absent|int32|int64|array|string|other)\z")
		|| !(DiagnosticArity is Integer) || DiagnosticArity < -1 || DiagnosticArity > 1024
		|| !(DiagnosticAvailability is String) || !RegExMatch(DiagnosticAvailability, "\A(?:available|unavailable)\z")
		return ""
	if DiagnosticType == "absent" && DiagnosticArity != 0
		return ""
	if DiagnosticType != "absent" && DiagnosticType != "array" && DiagnosticArity != 1
		return ""
	DiagnosticSize := "unknown"
	if DiagnosticAvailability == "available" {
		if (DiagnosticType != "int32" && DiagnosticType != "int64") || !Scalar.Has("size")
			|| !(Scalar["size"] is Integer) || Scalar["size"] < -1 || Scalar["size"] > 2147483647
			return ""
		DiagnosticSize := Format("{:d}", Scalar["size"])
	} else if Scalar.Has("size")
		return ""
	return "type=" . DiagnosticType . " arity=" . DiagnosticArity . " size=" . DiagnosticSize
}

_UpdaterNativeStagingDiagnosticFact(Diagnostic) {
	if !(Diagnostic is Map) || (Diagnostic.Count != 5 && Diagnostic.Count != 8)
		return ""
	for DiagnosticKey in Diagnostic
		if !(DiagnosticKey is String) || !RegExMatch(DiagnosticKey, "\A(?:schema_version|operation|exception|expected|actual|observed_stage|exception_family|hresult)\z")
			return ""
	DiagnosticOperation := Diagnostic.Get("operation", "")
	DiagnosticException := Diagnostic.Get("exception", "")
	if Type(Diagnostic.Get("schema_version", "")) != "Integer"
		|| !((Diagnostic.Count == 5 && Diagnostic["schema_version"] == 1)
			|| (Diagnostic.Count == 8 && Diagnostic["schema_version"] == 2))
		|| !(DiagnosticOperation is String) || !RegExMatch(DiagnosticOperation,
			"\A(?:metadata|content_length|minimum|digest_format|digest_read|budget|digest_compare|not_file_read)\z")
		|| !(DiagnosticException is String) || !RegExMatch(DiagnosticException,
			"\A(?:command_not_found|item_not_found|property_not_found|method_invocation|io|unauthorized|timeout|runtime|other)\z")
		return ""
	Extended := ""
	if Diagnostic["schema_version"] == 2 {
		ObservedStage := Diagnostic.Get("observed_stage", "")
		Family := Diagnostic.Get("exception_family", "")
		Code := Diagnostic.Get("hresult", "")
		if !(ObservedStage is String) || !RegExMatch(ObservedStage,
			"\A(?:proxy_resolve|proxy_connect|connect|tls|http|file_create|file_read|file_write|file_remove|file_rename|unknown)\z")
			|| !(Family is String) || !RegExMatch(Family,
				"\A(?:win32|web|argument|invalid_operation|security|type_initialization|command_not_found|item_not_found|property_not_found|method_invocation|io|unauthorized|timeout|runtime|other)\z")
			|| !(Code is Integer) || Code < -2147483648 || Code > 2147483647
			return ""
		Extended := " observed_stage=" . ObservedStage . " exception_family=" . Family . " hresult=" . Format("{:d}", Code)
	}
	DiagnosticExpected := _UpdaterNativeStagingScalarFact(Diagnostic.Get("expected", 0))
	DiagnosticActual := _UpdaterNativeStagingScalarFact(Diagnostic.Get("actual", 0))
	if DiagnosticExpected == "" || DiagnosticActual == ""
		return ""
	return "suboperation=" . DiagnosticOperation . " exception=" . DiagnosticException . Extended
		. " expected_" . StrReplace(DiagnosticExpected, " ", " expected_")
		. " actual_" . StrReplace(DiagnosticActual, " ", " actual_")
}

_UpdaterNativeStagingSetupDiagnosticFact(Fact) {
	if !(Fact is Map) || (Fact.Count != 6 && Fact.Count != 10)
		return ""
	for Key in Fact
		if !(Key is String) || !RegExMatch(Key, "\A(?:schema_version|site|line|exception|error|hresult|command|category|language|compiler)\z")
			return ""
	if !(Fact.Get("schema_version", "") is Integer) || Fact["schema_version"] != 1
		|| !(Fact.Get("line", "") is Integer) || Fact["line"] < 0 || Fact["line"] > 8192
		|| !(Fact.Get("hresult", "") is Integer) || Fact["hresult"] < -2147483648 || Fact["hresult"] > 2147483647
		return ""
	for Pair in [["site", "download_module_load|download_module_reconstruct|native_routes_load|route_call|unknown"],
		["exception", "invalid_operation|runtime|argument|io|other"],
		["error", "compiler|type_exists|type_missing|method_missing|command_missing|property_missing|method_invocation|variable_refused|route_refused|observation_seam|language_refused|json_invalid|other"]]
		if !(Fact.Get(Pair[1], "") is String) || !RegExMatch(Fact[Pair[1]], "\A(?:" . Pair[2] . ")\z")
			return ""
	Details := ""
	if Fact.Count == 10 {
		for Pair in [["command", "add_type|get_content|convert_json|other"],
			["category", "unknown|0|[1-9]|[12][0-9]|3[01]"],
			["language", "FullLanguage|ConstrainedLanguage|RestrictedLanguage|NoLanguage|unknown"],
			["compiler", "none|CS[0-9]{4}"]]
			if !(Fact.Get(Pair[1], "") is String) || !RegExMatch(Fact[Pair[1]], "\A(?:" . Pair[2] . ")\z")
				return ""
		if Fact["compiler"] != "none" && (Fact["command"] != "add_type" || Fact["error"] != "compiler")
			return ""
		Details := " command=" . Fact["command"] . " category=" . Fact["category"]
			. " language=" . Fact["language"] . " compiler=" . Fact["compiler"]
	}
	return "site=" . Fact["site"] . " line=" . Fact["line"] . " exception=" . Fact["exception"]
		. " error=" . Fact["error"] . " hresult=" . Format("{:d}", Fact["hresult"]) . Details
}

_UpdaterNativeEmitSetupDiagnostic(Run) {
	try {
		if !Run.HasOwnProp("StagingSetupDiagnosticPath")
			return
		Path := Run.StagingSetupDiagnosticPath
		if FSSize(Path) > 2048
			return
		Text := FSReadUtf8Exact(Path)
		if !(Text is String) || StrLen(Text) > 2048 || RegExMatch(Text, '"(?:schema_version|line|hresult)"\s*:\s*(?:true|false|null)\b')
			return
		for Key in ["schema_version", "site", "line", "exception", "error", "hresult", "command", "category", "language", "compiler"] {
			Pattern := '"' . Key . '"\s*:'
			if !RegExMatch(Text, Pattern, &Seen) {
				if Key == "command" || Key == "category" || Key == "language" || Key == "compiler"
					continue
				return
			}
			if RegExMatch(Text, Pattern, , Seen.Pos + Seen.Len)
				return
		}
		Fact := _UpdaterNativeStagingSetupDiagnosticFact(JsonParse(Text))
		if Fact != ""
			Run.RefusalDiagnosticPrinter.Call("::notice title=Windows staging setup::" . Fact)
	} catch Any {
		; Optional fixture observation never changes admission or refusal.
	}
}

_UpdaterNativeReadStagingDiagnostic(Path) {
	if !(Path is String) || Path == "" || FSSize(Path) > 2048
		return ""
	DiagnosticText := FSReadUtf8Exact(Path)
	if !(DiagnosticText is String) || StrLen(DiagnosticText) > 2048
		return ""
	if RegExMatch(DiagnosticText, '"(?:schema_version|arity|size|hresult)"\s*:\s*(?:true|false|null)\b')
		return ""
	return _UpdaterNativeStagingDiagnosticFact(JsonParse(DiagnosticText))
}

_UpdaterNativeRouteShapeFact(Fact) {
	if !(Fact is Map) || Fact.Count != 15 || !(Fact.Get("schema_version", "") is Integer) || Fact.Get("schema_version", 0) != 1
		return ""
	ExpectedKeys := "schema_version|selection_kind|selection_arity|ok_kind|ok_value|routes_kind|routes_count|max_routes_kind|max_routes_value|max_redirects_kind|max_redirects_value|receipt_kind|receipt_count|receipt_backend_kind|receipt_stage_kind"
	for Key in Fact
		if !(Key is String) || !RegExMatch(Key, "\A(?:" . ExpectedKeys . ")\z")
			return ""
	Kinds := "absent|bool|int32|int64|array|hashtable|string|other|unobserved"
	for Key in ["selection_kind", "ok_kind", "routes_kind", "max_routes_kind", "max_redirects_kind", "receipt_kind", "receipt_backend_kind", "receipt_stage_kind"]
		if !(Fact[Key] is String) || !RegExMatch(Fact[Key], "\A(?:" . Kinds . ")\z")
			return ""
	for Key in ["schema_version", "selection_arity", "routes_count", "max_routes_value", "max_redirects_value", "receipt_count"]
		if !(Fact[Key] is Integer) || Fact[Key] < -1 || Fact[Key] > 2147483647
			return ""
	if Fact["selection_kind"] == "unobserved" || Fact["selection_arity"] > 4096
		|| (Fact["selection_kind"] == "absent" && Fact["selection_arity"] != 0)
		|| (Fact["selection_kind"] != "absent" && Fact["selection_kind"] != "array" && Fact["selection_arity"] != 1)
		|| !(Fact["ok_value"] is String) || !RegExMatch(Fact["ok_value"], "\A(?:true|false|unavailable)\z")
		|| (Fact["ok_kind"] == "bool" ? Fact["ok_value"] == "unavailable" : Fact["ok_value"] != "unavailable")
		|| Fact["routes_count"] > 4096 || Fact["receipt_count"] > 64
		return ""
	if Fact["selection_kind"] != "hashtable" {
		for Key in ["ok_kind", "routes_kind", "max_routes_kind", "max_redirects_kind", "receipt_kind", "receipt_backend_kind", "receipt_stage_kind"]
			if Fact[Key] != "unobserved"
				return ""
	}
	for Pair in [["routes_kind", "routes_count", "array"], ["receipt_kind", "receipt_count", "hashtable"]]
		if Fact[Pair[1]] != Pair[3] && Fact[Pair[2]] != -1
			return ""
	for Prefix in ["max_routes", "max_redirects"]
		if Fact[Prefix . "_kind"] != "int32" && Fact[Prefix . "_kind"] != "int64" && Fact[Prefix . "_value"] != -1
			return ""
	Text := ""
	for Key in ["selection_kind", "selection_arity", "ok_kind", "ok_value", "routes_kind", "routes_count", "max_routes_kind", "max_routes_value", "max_redirects_kind", "max_redirects_value", "receipt_kind", "receipt_count", "receipt_backend_kind", "receipt_stage_kind"]
		Text .= (Text == "" ? "" : " ") . Key . "=" . Fact[Key]
	return Text
}

_UpdaterNativeReadRouteShape(Path) {
	if !(Path is String) || Path == "" || FSSize(Path) > 2048
		return ""
	Text := FSReadUtf8Exact(Path)
	if !(Text is String) || StrLen(Text) > 2048
		|| RegExMatch(Text, '"(?:schema_version|selection_arity|routes_count|max_routes_value|max_redirects_value|receipt_count)"\s*:\s*(?:true|false|null)\b')
		return ""
	return _UpdaterNativeRouteShapeFact(JsonParse(Text))
}

_UpdaterNativeEmitRouteShape(Run) {
	_UpdaterNativeEmitSetupDiagnostic(Run)
	try {
		if Run.HasOwnProp("RouteShapeDiagnosticPath") {
			Fact := _UpdaterNativeReadRouteShape(Run.RouteShapeDiagnosticPath)
			if Fact != ""
				Run.RefusalDiagnosticPrinter.Call("::notice title=Windows staging route shape diagnostic::" . Fact)
		}
	} catch Any {
		; Optional shape observation cannot replace the real route/refusal assertions.
	}
}

class _UpdaterNativeTransportOwner extends _ManagedRemoteFixtureOwner {
	__New() {
		super.__New()
		this.DownloadRuns := []
	}

	NewRun(Path, DeadlineMs := 30000, DenyFile := false) {
		Run := _UpdaterNativeDownloadRun(this, Path, DeadlineMs, DenyFile)
		this.DownloadRuns.Push(Run)
		Run.Start()
		return Run
	}

	RetireRequests() {
		Complete := true
		for Run in this.DownloadRuns {
			if !Run.Retire()
				Complete := false
		}
		return super.RetireRequests() && Complete
	}
}

class _UpdaterNativeDownloadRun {
	__New(Owner, Path, DeadlineMs, DenyFile) {
		this.Owner := Owner
		this.Path := Path
		this.DeadlineMs := DeadlineMs
		this.DenyFile := DenyFile
		this.Handle := 0
		this.NativeState := 0
		this.Results := []
		this.Directory := ""
		this.Closed := false
		this.Transport := 0
		this.OldBytes := "Independent existing-app bytes " . Owner.Identity
		; Receive the full production swap worker as UTF-8 data; never execute it.
		this.SwapBytes := _Updater_BuildSwapWorkerScript()
		this.Digest := "33bc8aab40703678c3ebe94d2dd8f2afff285dd901f9234e841e4679f8204fd5"
		this.RefusalDiagnosticPrinter := _TestPrint
		this.RefusalDiagnosticStatus := "not_requested"
	}

	OnNativeAdopt(State, Native) => this.NativeState := State
	OnDone(Code, Out, Err) => this.Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err))

	Start() {
		global _VendorDir, _SharedDir, UPDATER_MIN_EXE_SIZE_BYTES
		this.Directory := _SR_AcquireCaptureDirectory()
		this.CurrentExe := this.Directory . "existing.exe"
		this.NewExe := this.Directory . "staged.exe"
		this.SwapPath := this.Directory . "swap.ps1"
		this.StagingDiagnosticPath := this.Directory . "staging-diagnostic.json"
		this.StagingSetupDiagnosticPath := this.StagingDiagnosticPath . ".setup"
		this.RouteShapeDiagnosticPath := this.Directory . "route-shape.json"
		FileAppend(this.OldBytes, this.CurrentExe, "UTF-8-RAW")
		if this.DenyFile
			DirCreate(this.NewExe)
		AssertEqual(524288, UPDATER_MIN_EXE_SIZE_BYTES,
			"fixture bytes have an independent fixed size; a changed minimum requires explicit fixture review")
		; The 407 relay has its own reserved authority; HTTPS PAC paths are not routing identity.
		Host := this.Path == "/updater/407" ? "updater-refusal.managed-fixture.invalid" : "managed-fixture.invalid"
		Url := "https://" . Host . ":" . this.Owner.State["tls_port"] . this.Path
		this.StartedTick := A_TickCount
		this.Transport := _Updater_BuildStagingTransport(
			_UpdaterNativeObservedStagingScript(_Updater_BuildStagingWorkerScript()), this.SwapBytes, Url, this.Digest,
			this.NewExe, this.SwapPath, this.CurrentExe, UPDATER_MIN_EXE_SIZE_BYTES, 5000,
			_VendorDir . "\ergopti_updater_download.ps1", this.DeadlineMs, this.StartedTick,
			_SharedDir . "\modules\network\proxy_policy.json",
			_SharedDir . "\modules\updater\defaults.json")
		try {
			ScriptName := this.Transport.Environment[1].Name
			Prefix := SubStr(ScriptName, 1, StrLen(ScriptName) - StrLen("_SCRIPT"))
			Pair := {Name: Prefix . "_TEST_PAC", Value: "http://127.0.0.1:" . this.Owner.State["http_port"] . "/updater.pac"}
			this.Transport.Environment.Push(Pair)
			DiagnosticPair := {Name: Prefix . "_TEST_STAGING_DIAGNOSTIC", Value: this.StagingDiagnosticPath}
			this.Transport.Environment.Push(DiagnosticPair)
			RouteShapePair := {Name: Prefix . "_TEST_ROUTE_SHAPE", Value: this.RouteShapeDiagnosticPath}
			this.Transport.Environment.Push(RouteShapePair)
			EnvSet(RouteShapePair.Name, RouteShapePair.Value)
			EnvSet(DiagnosticPair.Name, DiagnosticPair.Value)
			EnvSet(Pair.Name, Pair.Value)
			; Add declared trusted callbacks to the real transport invocation only.
			; Passive observation chunks preserve every original worker operation and guard.
			Admission := '$env:ERGOPTI_FIXTURE_STAGING_ROUTE_SHAPE=$env:' . RouteShapePair.Name . ';$env:ERGOPTI_FIXTURE_STAGING_DIAGNOSTIC=$env:' . DiagnosticPair.Name . ';$ownedPac=$env:' . Pair.Name . ';'
				. '$reader={param($MaxBytes)[pscustomobject]@{Ok=$true;AutoDetect=$false;Absent=$false;PacUrl=$ownedPac;Proxy="";Bypass="";NativeError=0;FailureOrigin=""}}.GetNewClosure();'
				. '$environment={param($Name)return ""};'
			Bootstrap := Admission . this.Transport.Bootstrap . ' -ReadConfig $reader -ReadEnvironment $environment'
			Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
				_Updater_EncodePowerShellCommand(Bootstrap)]
			this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
				ObjBindMethod(this, "OnDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
			AssertTrue(this.Handle.start(), "actual staging private Job must start")
		} finally _Updater_ClearStagingTransport(this.Transport)
	}

	Wait(BudgetMs := 35000) {
		Started := A_TickCount
		while this.Results.Length == 0 && !TickExpired64(Started, BudgetMs) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, this.Results.Length, "actual private Job callback must settle once")
		AssertTrue(this.NativeState is Map && this.NativeState.Get("TreeQuiesced", false),
			"callback must acknowledge actual Job-empty, process exit and native handle retirement")
		AssertTrue(this.Handle.terminate(), "closed actual worker retirement is idempotent")
		AssertEqual("", this.Results[1]["stderr"], "actual staging receipt never diagnoses from stderr")
		AssertEqual(this.OldBytes, FileRead(this.CurrentExe, "UTF-8"), "all actual refusals preserve exact existing app bytes")
		return this.Results[1]
	}

	Accepted() {
		Result := this.Wait()
		if Result["exit"] != 0 {
			_UpdaterNativeEmitRouteShape(this)
			this.RefusalDiagnosticStatus := "unavailable"
			this.StagingDiagnosticStatus := "unavailable"
			try {
				if this.HasOwnProp("StagingDiagnosticPath") {
					StagingFact := _UpdaterNativeReadStagingDiagnostic(this.StagingDiagnosticPath)
					if StagingFact != "" {
						this.RefusalDiagnosticPrinter.Call("::notice title=Windows staging suboperation diagnostic::" . StagingFact)
						this.StagingDiagnosticStatus := "reported"
					}
				}
			} catch Any {
				this.StagingDiagnosticStatus := "unavailable"
			}
			try {
				Failure := _Updater_ParseStagingFailure(Result["stdout"])
				Reason := _ManagedRemoteFixtureDiagnosticEnum(Failure["reason"], "download|verify|deadline")
				if Failure["valid"] && Reason != "unknown" {
					this.RefusalDiagnosticPrinter.Call("::notice title=Windows native updater acceptance refusal diagnostic::reason="
						. Reason . " " . _UpdaterNativeRefusalDiagnostic("", Failure["receipt"]))
					this.RefusalDiagnosticStatus := "reported"
				}
			} catch Any {
				; A diagnostic refusal cannot replace the original native exit assertion.
				this.RefusalDiagnosticStatus := "unavailable"
			}
		}
		AssertEqual(0, Result["exit"])
		AssertEqual("READY", Result["stdout"], "actual size/digest/persistence checks must produce exact READY")
		Bytes := FileRead(this.NewExe, "RAW")
		AssertEqual(524288, Bytes.Size, "independent native body length")
		AssertEqual(this.Digest, CryptoSha256Bytes(Bytes), "independent fixed expected digest matches actual staged bytes")
		AssertEqual(this.SwapBytes, FileRead(this.SwapPath, "UTF-8"), "actual swap placeholder was persisted as input, never run")
	}

	Refused(Reason, Stage := "", HttpStatus := 0) {
		Result := this.Wait()
		AssertTrue(Result["exit"] != 0, "actual refusal cannot return successful READY")
		Failure := _Updater_ParseStagingFailure(Result["stdout"])
		AssertTrue(Failure["valid"], "actual worker must publish a bounded native receipt")
		this.RefusalDiagnosticStatus := "unavailable"
		try {
			this.RefusalDiagnosticPrinter.Call("::notice title=Windows native updater refusal diagnostic::"
				. _UpdaterNativeRefusalDiagnostic(Stage, Failure["receipt"]))
			this.RefusalDiagnosticStatus := "reported"
		} catch Any {
			; Reporting refusal cannot replace the original native acceptance assertions.
			this.RefusalDiagnosticStatus := "unavailable"
		}
		this.StagingDiagnosticStatus := "unavailable"
		try {
			if this.HasOwnProp("StagingDiagnosticPath") {
				StagingFact := _UpdaterNativeReadStagingDiagnostic(this.StagingDiagnosticPath)
				if StagingFact != "" {
					this.RefusalDiagnosticPrinter.Call("::notice title=Windows staging suboperation diagnostic::" . StagingFact)
					this.StagingDiagnosticStatus := "reported"
				}
			}
		} catch Any {
			; Optional observation cannot replace the original refusal assertion.
			this.StagingDiagnosticStatus := "unavailable"
		}
		_UpdaterNativeEmitRouteShape(this)
		AssertEqual(Reason, Failure["reason"])
		if Stage != ""
			AssertEqual(Stage, Failure["receipt"].Get("stage", ""))
		if HttpStatus {
			AssertEqual(HttpStatus, Failure["receipt"].Get("http_status", 0), "typed actual response status")
			AssertEqual("unavailable", Failure["receipt"].Get("http_response_source", ""), "selected relay cannot fabricate response-source evidence")
			AssertTrue(!Failure["receipt"].Has("proxy_connect_status"), "origin/407 response cannot fabricate CONNECT provenance")
		}
		AssertTrue(!FileExist(this.SwapPath), "actual refusal cannot leave a runnable swap input")
		if !this.DenyFile
			AssertTrue(!FileExist(this.NewExe), "actual refused staged executable must be removed after native retirement")
		return Failure
	}

	AssertCancelled() {
		; terminate() deliberately suppresses OnDone. Qualification comes from
		; the exact actual native terminal owner, never an invented callback.
		AssertTrue(this.NativeState is Map && this.NativeState.Get("TreeQuiesced", false),
			"actual cancellation acknowledges Job-empty and native process/handle retirement")
		Claim := this.NativeState.Get("TerminalClaim", 0)
		AssertTrue(Claim is Map && Claim.Get("TreeQuiesced", false), "exact native terminal claim remains inspectable")
		AssertTrue(Claim.Get("NativeExitObserved", false), "exact native process exit was observed before handle closure")
		for Name in ["ProcessHandle", "ThreadHandle", "JobHandle"]
			AssertEqual(0, Claim.Get(Name, -1), "actual owned native handle closes: " . Name)
		AssertEqual(0, Claim.Get("NativeErrors", []).Length, "native retirement errors cannot borrow quiescence success")
		AssertTrue(Claim.Get("ExitCode", 0) != 0, "actual cancellation/deadline terminal cannot report successful staging")
		AssertTrue(this.Results.Length <= 1, "suppressed completion cannot dispatch twice")
		for Result in this.Results
			AssertTrue(Result["exit"] != 0 && Result["stdout"] != "READY", "a naturally completed refusal cannot become successful READY")
		AssertTrue(this.Handle.terminate(), "actual native retirement retry is idempotent")
		AssertEqual(this.OldBytes, FileRead(this.CurrentExe, "UTF-8"), "actual cancellation preserves exact existing app bytes")
	}

	Retire() {
		if this.Closed
			return true
		if IsObject(this.Handle) {
			if !this.Handle.terminate()
				return false
			if !(this.NativeState is Map) || !this.NativeState.Get("TreeQuiesced", false)
				return false
		}
		if this.Directory != "" {
			for Name in ["CurrentExe", "NewExe", "SwapPath", "StagingDiagnosticPath", "StagingSetupDiagnosticPath", "RouteShapeDiagnosticPath"] {
				if !this.HasOwnProp(Name)
					continue
				Path := this.%Name%
				if DirExist(Path)
				DirDelete(Path, false)
				else if FileExist(Path)
					FileDelete(Path)
			}
			DirDelete(this.Directory, false)
			this.Directory := ""
		}
		this.Closed := true
		return true
	}
}

class _UpdaterNativeRefusalDiagnosticControl extends _UpdaterNativeDownloadRun {
	__New(Printer, DotNet := false) {
		this.RefusalDiagnosticPrinter := Printer
		this.RefusalDiagnosticStatus := "not_requested"
		this.DotNet := DotNet
	}

	Wait() {
		if this.HasOwnProp("FixtureResult")
			return this.FixtureResult
		if this.DotNet
			return Map("exit", 1, "stdout",
				'{"schema_version":1,"state":"failed","operation":"download","reason":"download",'
				. '"receipt":{"backend":"dotnet","stage":"connect","failure_provenance":"unknown",'
				. '"native_errno_domain":"win32","native_errno":"12007","tls_status":"unavailable"}}')
		return Map("exit", 1, "stdout",
			'{"schema_version":1,"state":"failed","operation":"download","reason":"download",'
			. '"receipt":{"backend":"curl","stage":"connect","failure_provenance":"verified",'
			. '"curl_exit":6,"http_status":0,"proxy_connect_status":0,"proxy_mode":"direct"}}')
	}
}

/** The actual acceptance entry must retain its first exit assertion. */
_UpdaterNativeAcceptedPrimary(Run) {
	Caught := false
	try Run.Accepted()
	catch as Failure {
		Caught := true
		AssertContains(Failure.Message, "expected: <0>, actual: <1>",
			"diagnostic processing cannot overwrite the original acceptance assertion")
	}
	AssertTrue(Caught, "a refused actual acceptance entry must still fail")
}

_UpdaterNativeAcceptedReports(Contract) {
	for DotNet in [false, true] {
		for Reason in ["download", "verify", "deadline"] {
			Observed := Map("calls", 0, "fact", "")
			Run := _UpdaterNativeRefusalDiagnosticControl(
				(Text) => (Observed["calls"] += 1, Observed["fact"] := Text), DotNet)
			Result := Run.Wait()
			Result["stdout"] := StrReplace(Result["stdout"], '"reason":"download"', '"reason":"' . Reason . '"')
			Run.FixtureResult := Result
			_UpdaterNativeAcceptedPrimary(Run)
			AssertEqual(1, Observed["calls"], "the actual acceptance entry diagnoses before its exit assertion")
			AssertEqual("reported", Run.RefusalDiagnosticStatus)
			AssertContains(Observed["fact"], "reason=" . Reason . " expected_stage=unknown observed_stage=connect")
			if DotNet
				AssertContains(Observed["fact"], "native_errno_domain=win32 native_errno=12007 tls_status=unavailable")
			else
				AssertContains(Observed["fact"], "curl_exit=6 http_status=0 proxy_connect_status=0 proxy_mode=direct")
			AssertFalse(InStr(Observed["fact"], '"schema_version"'), "raw staging envelopes never enter the diagnostic")
		}
	}
}
Test("updater native: failed acceptance emits bounded native facts (managed-fixture-accepted-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeAcceptedReports))

_UpdaterNativeAcceptedReporterRefuses(Contract) {
	Control := Map("calls", 0)
	Run := _UpdaterNativeRefusalDiagnosticControl(_ManagedRemoteStateWaitPrinterRefused.Bind(Control))
	_UpdaterNativeAcceptedPrimary(Run)
	AssertEqual(1, Control["calls"], "a refused diagnostic sink is attempted once without recursion")
	AssertEqual("unavailable", Run.RefusalDiagnosticStatus)
}
Test("updater native: acceptance reporter refusal preserves the primary assertion (managed-fixture-accepted-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeAcceptedReporterRefuses))

_UpdaterNativeAcceptedMalformedRefuses(Contract) {
	Private := "PRIVATE_ACCEPTANCE_CONTENT"
	Control := _UpdaterNativeRefusalDiagnosticControl((Text) => 0)
	Valid := Control.Wait()["stdout"]
	for Raw in [Private, "", "[]", 0, Valid . Private,
		StrReplace(Valid, '"reason":"download"', '"reason":"' . Private . '"'),
		StrReplace(Valid, '"reason":"download"', '"reason":"persist"'),
		StrReplace(Valid, '"backend":"curl"', '"backend":"' . Private . '"'),
		StrReplace(Valid, '"curl_exit":6', '"curl_exit":"' . Private . '"'),
		StrReplace(Valid, '"schema_version":1', '"schema_version":1,"private":"' . Private . '"')] {
		AssertFalse(_Updater_ParseStagingFailure(Raw)["valid"], "each malformed control reaches the actual parser refusal")
		Observed := Map("calls", 0)
		Run := _UpdaterNativeRefusalDiagnosticControl((Text) => (Observed["calls"] += 1))
		Run.FixtureResult := Map("exit", 1, "stdout", Raw)
		_UpdaterNativeAcceptedPrimary(Run)
		AssertEqual(0, Observed["calls"], "invalid or private staging data cannot reach the diagnostic sink")
		AssertEqual("unavailable", Run.RefusalDiagnosticStatus)
	}
	Observed := Map("calls", 0)
	Run := _UpdaterNativeRefusalDiagnosticControl((Text) => (Observed["calls"] += 1))
	Run.FixtureResult := Map("exit", 0, "stdout", "NOT_READY")
	Caught := false
	try Run.Accepted()
	catch as Failure {
		Caught := true
		AssertContains(Failure.Message, "expected: <READY>, actual: <NOT_READY>", "the original successful-exit READY assertion remains mandatory")
	}
	AssertTrue(Caught)
	AssertEqual(0, Observed["calls"], "successful exit never requests a refusal diagnostic")
	AssertEqual("not_requested", Run.RefusalDiagnosticStatus)
}
Test("updater native: acceptance diagnostics refuse malformed data and never relax READY (managed-fixture-accepted-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeAcceptedMalformedRefuses))

_UpdaterNativeRefusalReports(Contract) {
	Observed := Map("calls", 0, "fact", "")
	Run := _UpdaterNativeRefusalDiagnosticControl((Text) => (Observed["calls"] += 1, Observed["fact"] := Text))
	Caught := false
	try Run.Refused("download", "tls")
	catch as Failure {
		Caught := true
		AssertContains(Failure.Message, "expected: <tls>, actual: <connect>", "the original stage assertion retains priority")
	}
	AssertTrue(Caught)
	AssertEqual(1, Observed["calls"], "the actual refusal entry reports native facts before a stage assertion")
	AssertContains(Observed["fact"], "curl_exit=6")
	AssertContains(Observed["fact"], "proxy_mode=direct")
}
Test("updater native: refusal emits bounded native facts (managed-fixture-refusal-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeRefusalReports))

_UpdaterNativeRefusalProjectionAndRefusal(Contract) {
	Private := "PRIVATE_NATIVE_CONTENT"
	Fact := _UpdaterNativeRefusalDiagnostic(Private,
		Map("stage", Private, "backend", Private, "curl_exit", "6", "http_status", 2147483648,
			"proxy_connect_status", -1, "proxy_mode", Private, "stderr", Private))
	AssertFalse(InStr(Fact, Private), "no unknown scalar or unused private field can enter the diagnostic")
	AssertContains(Fact, "curl_exit=unknown http_status=unknown proxy_connect_status=unknown proxy_mode=unknown")
	Fact := _UpdaterNativeRefusalDiagnostic("tls",
		Map("stage", "tls", "backend", "curl", "curl_exit", 60, "http_status", 0, "proxy_connect_status", 200, "proxy_mode", "selected"))
	AssertContains(Fact, "curl_exit=60 http_status=0 proxy_connect_status=200 proxy_mode=selected")
	Control := Map("calls", 0)
	Run := _UpdaterNativeRefusalDiagnosticControl(_ManagedRemoteStateWaitPrinterRefused.Bind(Control))
	Caught := false
	try Run.Refused("download", "tls")
	catch as Failure {
		Caught := true
		AssertContains(Failure.Message, "expected: <tls>, actual: <connect>", "reporter refusal cannot overwrite a primary stage assertion")
	}
	AssertTrue(Caught)
	AssertEqual(1, Control["calls"], "a refused sink is invoked once without recursion")
	AssertEqual("unavailable", Run.RefusalDiagnosticStatus)
}
Test("updater native: refusal diagnostic excludes content and preserves assertions (managed-fixture-refusal-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeRefusalProjectionAndRefusal))

_UpdaterNativeDotNetProjection(Contract) {
	Observed := Map("calls", 0, "fact", "")
	Run := _UpdaterNativeRefusalDiagnosticControl((Text) => (Observed["calls"] += 1, Observed["fact"] := Text), true)
	Caught := false
	try Run.Refused("download", "tls")
	catch as Failure {
		Caught := true
		AssertContains(Failure.Message, "expected: <tls>, actual: <connect>")
	}
	AssertTrue(Caught)
	AssertEqual(1, Observed["calls"])
	AssertContains(Observed["fact"], "backend=dotnet")
	AssertContains(Observed["fact"], "native_errno_domain=win32 native_errno=12007 tls_status=unavailable")
	for Pair in [["-2147483648", "-2147483648"], ["2147483647", "2147483647"],
		["2147483648", "unknown"], ["-2147483649", "unknown"], ["PRIVATE_ERRNO", "unknown"], [12007, "unknown"]] {
		Fact := _UpdaterNativeRefusalDiagnostic("tls", Map("native_errno", Pair[1]))
		AssertContains(Fact, "native_errno=" . Pair[2] . " tls_status=unknown")
		AssertFalse(InStr(Fact, "PRIVATE_ERRNO"))
	}
	Fact := _UpdaterNativeRefusalDiagnostic("tls", Map("native_errno_domain", "PRIVATE_DOMAIN", "tls_status", "PRIVATE_TLS"))
	AssertContains(Fact, "native_errno_domain=unknown native_errno=unknown tls_status=unknown")
}
Test("updater native: dotnet receipt exposes only typed native facts (managed-fixture-refusal-diagnostic)",
	_UMF_WithContract.Bind(_UpdaterNativeDotNetProjection))

_UpdaterNative_Close(Fixture) {
	Closed := Fixture.Close()
	if !Closed
		Fixture.RetainCleanup()
	AssertTrue(Closed, "actual staging, fixture services, exact root and private inputs must retire")
	if Fixture.RootThumbprint != "" {
		AssertTrue(Fixture.RootRemovalVerified, "independent exact-thumbprint store removal acknowledgement")
		AssertTrue(Fixture.GracefulReceiptVerified, "service cleanup failures cannot borrow independent root removal success")
	}
	AssertEqual(0, Fixture.Events.Count, "actual owned native event handles close")
}

_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal(Contract, Fixture := unset) {
	if !IsSet(Fixture)
		Fixture := _UpdaterNativeTransportOwner()
	PrimaryFailure := 0
	BodyFailed := false
	try {
		Fixture.Start("ServeUpdater")
		for Port in ["second_proxy_port", "refusal_proxy_port"]
			AssertTrue(Fixture.State.Get(Port, 0) > 0 && Fixture.State[Port] <= 65535)
		Untrusted := Fixture.NewRun("/updater/good?marker=staging-fixture")
		Failure := Untrusted.Refused("download", "tls")
		AssertEqual("certificate", Contract.Classify(Failure["receipt"], Map())["cause"], "actual untrusted system-store refusal is typed")
		Fixture.Observe()
		AssertEqual(0, Fixture.State["DownloadRequests"], "untrusted TLS reaches no HTTP download handler")
		Fixture.ChangeTrust(true)
		BeforeSecond := Fixture.State["SecondProxyConnects"]
		BeforeProxy := Fixture.State["ProxyConnects"]
		Trusted := Fixture.NewRun("/updater/start")
		Trusted.Accepted()
		Fixture.Observe()
		AssertEqual(1, Fixture.State["DownloadRedirects"], "actual initial route delivered one redirect")
		AssertEqual(1, Fixture.State["DownloadGood"], "actual full redirected path/query reached owned origin")
		AssertEqual(BeforeSecond + 1, Fixture.State["SecondProxyConnects"], "only the final redirected hop selects the second actual PAC relay")
		AssertEqual(BeforeProxy + 2, Fixture.State["ProxyConnects"], "both exact redirect hops acquire actual owned CONNECT transports")
		AssertTrue(Fixture.State["PacRequests"] >= 1, "actual WinHTTP PAC engine fetched owned script")
		Fixture.NewRun("/updater/wrong-digest").Refused("verify")
		Fixture.NewRun("/updater/small").Refused("verify")
		Fixture.NewRun("/updater/truncated").Refused("download")
		Origin401 := Fixture.NewRun("/updater/401").Refused("download", "http", 401)
		Origin403 := Fixture.NewRun("/updater/403").Refused("download", "http", 403)
		Relay407 := Fixture.NewRun("/updater/407").Refused("download", "http", 407)
		for Failure in [Origin401, Origin403, Relay407]
			AssertEqual("unknown", Contract.Classify(Failure["receipt"], Map())["cause"], "actual HTTP status alone cannot diagnose proxy authentication/blocking")
		FileDenial := Fixture.NewRun("/updater/good?marker=staging-fixture", 30000, true).Refused("download", "file_remove")
		AssertEqual("permission", Contract.Classify(FileDenial["receipt"], Map())["cause"], "actual owned directory-as-file denial is typed Win32 permission")
		Fixture.Observe()
		AssertEqual(1, Fixture.State["DownloadWrongDigest"])
		AssertEqual(1, Fixture.State["DownloadSmall"])
		AssertEqual(1, Fixture.State["DownloadTruncated"])
		AssertEqual(1, Fixture.State["DownloadOrigin401"])
		AssertEqual(1, Fixture.State["DownloadOrigin403"])
		AssertTrue(Fixture.State["ProxyRefusals"] >= 1, "owned actual relay issued Basic-only HTTP407")
		AssertEqual(0, Fixture.State["BasicCredentials"], "current-user credentials cannot downgrade to Basic")
		AssertEqual(0, Fixture.State["DownloadCredentials"], "origin receives no default/proxy credentials, including challenge retries")
		Fixture.ChangeTrust(false)
		Removed := Fixture.NewRun("/updater/good?marker=staging-fixture")
		Failure := Removed.Refused("download", "tls")
		AssertEqual("certificate", Contract.Classify(Failure["receipt"], Map())["cause"])
		Fixture.Observe()
		AssertEqual(7, Fixture.State["DownloadRequests"], "removal and filesystem refusal reach no additional HTTPS handlers")
	} catch Any as Failure {
		PrimaryFailure := Failure
		BodyFailed := true
	} finally _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, _UpdaterNative_Close.Bind(Fixture))
}

_UpdaterNative_WithContract(Callback) {
	global _UpdaterManagedFailureContract, _SharedDir
	Saved := _UpdaterManagedFailureContract
	try {
		_UpdaterManagedFailureContract := ManagedNetworkFailureContract(
			JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8")))
		Callback.Call(_UpdaterManagedFailureContract)
	} finally _UpdaterManagedFailureContract := Saved
}
Test("updater native: actual generated staging CA/PAC integrity and refusals preserve old app",
	(*) => _UpdaterNative_WithContract(_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal))

_UpdaterNative_ActualDeadlineAndCancellation(Contract, Fixture := unset) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	AssertTrue(!_UpdaterDownloadInProgress && !IsObject(_UpdaterDownloadWorker)
		&& !(_UpdaterSwapOwner is Map), "native qualification cannot borrow a foreign live updater transaction")
	Saved := [_UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest,
		_UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch,
		_UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation,
		_UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS]
	if !IsSet(Fixture)
		Fixture := _UpdaterNativeTransportOwner()
	PrimaryFailure := 0
	BodyFailed := false
	try {
		Fixture.Start("ServeUpdater")
		Fixture.ChangeTrust(true)
		for Kind in ["cancel", "deadline"] {
			State := {Notices: 0}
			Phases := []
			; A controlled shorter budget is passed to BOTH the real parent and
			; the real generated helper, with one original native start tick.
			Budget := Kind == "deadline" ? 15000 : 30000
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Budget
			Run := Fixture.NewRun("/updater/slow", Budget)
			PreviousCritical := Critical("On")
			try {
				_UpdaterDownloadInProgress := true
				_UpdaterDownloadWorker := Run.Handle
				_UpdaterDownloadRequest := 0
				_UpdaterDownloadArtifacts := {NewExe: Run.NewExe, SwapScript: Run.SwapPath}
				_UpdaterDownloadStartedTick := Run.StartedTick
				Epoch := ++_UpdaterSelfUpdateEpoch
				_UpdaterSwapOwner := 0
				_UpdaterExitIntent := 0
				_UpdaterExitInvocation := 0
				_UpdaterManagedFailureOwner := 0
				_UpdaterInstallObserver := (Phase, Reason) => Phases.Push(Phase)
			} finally Critical(PreviousCritical)
			WaitStart := A_TickCount
			while !FileExist(Run.NewExe) && Run.Results.Length == 0 && !TickExpired64(WaitStart, 10000) {
				_SR_TreePoll()
				Sleep(10)
			}
			if !FileExist(Run.NewExe) || Run.Results.Length != 0
				_UpdaterNativeEmitPartialStageDiagnostic(Run, Kind)
			AssertTrue(FileExist(Run.NewExe) && Run.Results.Length == 0,
				"actual child must own a live partial stage before cancellation/deadline admission")
			Fixture.Observe()
			AssertTrue(Fixture.State["DownloadSlow"] >= (Kind == "cancel" ? 1 : 2),
				"actual owned TLS body handler must be live before retirement")
			AssertEqual(Run.StartedTick, _UpdaterDownloadStartedTick, "parent retains exact original worker clock")
			if Kind == "cancel" {
				AssertTrue(_Updater_CancelSelfUpdateTransaction("Owned native acceptance cancellation.", false, false, Epoch),
					"actual parent cancellation must consume the exact live transaction")
			} else {
				while !TickExpired64(Run.StartedTick, Budget) {
					_SR_TreePoll()
					Sleep(10)
				}
				AssertTrue(_Updater_EnforceDownloadDeadline(A_TickCount, false,
					(Message, Options) => State.Notices += 1,
					_Updater_CancelSelfUpdateTransaction, Epoch),
					"actual monotonic parent budget must consume the exact transaction")
				AssertEqual(1, State.Notices, "actual deadline has one visible primary terminal")
			}
			Run.AssertCancelled()
			AssertTrue(Run.NativeState.Get("TreeQuiesced", false), "native Job/process/handle closure cannot be supplied by a stub")
			AssertTrue(!FileExist(Run.NewExe) && !FileExist(Run.SwapPath),
				"actual parent cancellation must remove its partial owned staging inputs")
			AssertEqual(false, _UpdaterDownloadInProgress)
			AssertEqual(0, _UpdaterDownloadWorker)
			AssertEqual(0, _UpdaterSwapOwner, "actual deadline/cancellation cannot dispatch a swap")
			AssertEqual(1, Phases.Length, "one actual failed terminal, no installing/restarting phase")
			AssertEqual("failed", Phases[1])
			AssertEqual(0, _UpdaterManagedFailureOwner, "cancelled or expired input cannot create retry consent")
			AssertEqual(false, _Updater_CancelSelfUpdateTransaction("Duplicate native cancellation.", false, false),
				"idempotent cancellation cannot publish another terminal")
			AssertEqual(1, Phases.Length)
		}
	} catch Any as Failure {
		PrimaryFailure := Failure
		BodyFailed := true
	} finally {
		; The fixture ledger independently retains every actual worker even if
		; the production cancellation path refuses or an assertion throws.
		try _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, _UpdaterNative_Close.Bind(Fixture))
		finally {
			_UpdaterDownloadInProgress := Saved[1]
			_UpdaterDownloadWorker := Saved[2]
			_UpdaterDownloadRequest := Saved[3]
			_UpdaterDownloadArtifacts := Saved[4]
			_UpdaterDownloadStartedTick := Saved[5]
			_UpdaterSelfUpdateEpoch := Saved[6]
			_UpdaterSwapOwner := Saved[7]
			_UpdaterExitIntent := Saved[8]
			_UpdaterExitInvocation := Saved[9]
			_UpdaterInstallObserver := Saved[10]
			_UpdaterManagedFailureOwner := Saved[11]
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Saved[12]
		}
	}
}
Test("updater native: actual original deadline/cancellation retire owned Job and partial stage",
	(*) => _UpdaterNative_WithContract(_UpdaterNative_ActualDeadlineAndCancellation))

_UpdaterNativePrimaryActualEntryControl(Entry) {
	Fixture := _ManagedRemotePrimaryControlFixture()
	Observed := 0
	try Entry.Call(Map(), Fixture)
	catch as Failure
		Observed := Failure
	AssertEqual(1, Fixture.StartCalls, "the real updater entry must execute the controlled failing body")
	AssertEqual(1, Fixture.CloseCalls, "the original updater cleanup assertions must execute once")
	AssertTrue(Observed == Fixture.Primary, "the real updater entry must retain the exact body exception through failed graceful cleanup")
}
Test("updater native: trust entry preserves primary through graceful refusal (managed-fixture-primary-cleanup)",
	_UpdaterNativePrimaryActualEntryControl.Bind(_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal))
Test("updater native: cancellation entry preserves primary through graceful refusal (managed-fixture-primary-cleanup)",
	_UpdaterNativePrimaryActualEntryControl.Bind(_UpdaterNative_ActualDeadlineAndCancellation))

_UpdaterNativeStagingFactControls() {
	StagingExpected := Map("type", "array", "arity", 2, "size_available", "unavailable")
	StagingActual := Map("type", "int64", "arity", 1, "size_available", "available", "size", 524288)
	StagingRecord := Map("schema_version", 1, "operation", "content_length", "exception", "runtime",
		"expected", StagingExpected, "actual", StagingActual)
	StagingText := _UpdaterNativeStagingDiagnosticFact(StagingRecord)
	AssertContains(StagingText, "expected_type=array expected_arity=2 expected_size=unknown",
		"an array cannot invent a scalar expected length")
	AssertContains(StagingText, "actual_size=524288", "actual metadata size stays an integer")
	StagingActual["size"] := "524288"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(StagingRecord), "string sizes are refused")
	StagingActual["size"] := 524288
	StagingExpected["arity"] := "2"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(StagingRecord), "string arity is refused")
	StagingExpected["arity"] := 2
	StagingRecord["private_message"] := "PRIVATE_SECRET"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(StagingRecord), "private fields never reach a notice")
	StagingRecord.Delete("private_message")
	StagingRecord["operation"] := "PRIVATE_OPERATION"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(StagingRecord), "unknown operations are refused")
	StagingRecord["operation"] := "content_length"
	StagingExpected["size"] := 42
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(StagingRecord), "unavailable size cannot carry an invented value")
}
Test("updater fixture: staging diagnostics keep closed scalar shapes and privacy",
	_UpdaterNativeStagingFactControls)

; Observe the captured terminal before the original live-stage assertion fires.
_UpdaterNativePartialStageDiagnostic(Kind, Completions, State, Elapsed) {
	Fact := "kind=" . _ManagedRemoteFixtureDiagnosticEnum(Kind, "cancel|deadline")
		. " elapsed_ms=" . _ManagedRemoteFixtureGenerationInteger(Elapsed, 0, 2147483647)
		. " callbacks=" . (Completions is Array ? _ManagedRemoteFixtureGenerationInteger(Completions.Length, 0, 65535) : "unknown")
		. " tree_quiesced=" . (State is Map ? _ManagedRemoteFixtureDiagnosticBoolean(State.Get("TreeQuiesced", "")) : "unknown")
	if !(Completions is Array) || Completions.Length != 1 || !(Completions[1] is Map)
		return Fact . " exit=unknown failure=unavailable"
	Completion := Completions[1]
	Fact .= " exit=" . _ManagedRemoteFixtureGenerationInteger(Completion.Get("exit", ""), -2147483648, 4294967295)
	Output := Completion.Get("stdout", 0)
	if !(Output is String)
		return Fact . " failure=invalid"
	Failure := _Updater_ParseStagingFailure(Output)
	if !Failure["valid"]
		return Fact . " failure=invalid"
	return Fact . " failure=admitted reason=" . _ManagedRemoteFixtureDiagnosticEnum(Failure["reason"], "download|verify|deadline")
		. " " . _UpdaterNativeRefusalDiagnostic("", Failure["receipt"])
}

_UpdaterNativeEmitPartialStageDiagnostic(Run, Kind) {
	_UpdaterNativeEmitRouteShape(Run)
	try {
		Elapsed := TickElapsed64(Run.StartedTick)
		Fact := _UpdaterNativePartialStageDiagnostic(Kind, Run.Results, Run.NativeState, Elapsed)
		Run.RefusalDiagnosticPrinter.Call("::notice title=Windows native partial stage diagnostic::" . Fact)
		if Run.HasOwnProp("StagingDiagnosticPath") {
			StagingFact := _UpdaterNativeReadStagingDiagnostic(Run.StagingDiagnosticPath)
			if StagingFact != ""
				Run.RefusalDiagnosticPrinter.Call("::notice title=Windows staging suboperation diagnostic::" . StagingFact)
		}
	} catch Any {
		; Observation refusal cannot replace or satisfy the live-stage assertion.
	}
}

_UpdaterNativePartialStageDiagnosticControls(Contract) {
	Output := '{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"tls","failure_provenance":"verified","tls_status":"untrusted_certificate"},"cleanup_debt":[],"native_cleanup_debt":false}'
	Fact := _UpdaterNativePartialStageDiagnostic("cancel", [Map("exit", 1, "stdout", Output)], Map("TreeQuiesced", true), 1500)
	AssertContains(Fact, "kind=cancel elapsed_ms=1500 callbacks=1 tree_quiesced=true exit=1 failure=admitted reason=download")
	AssertContains(Fact, "observed_stage=tls backend=dotnet")
	AssertContains(Fact, "tls_status=untrusted_certificate")
	Fact := _UpdaterNativePartialStageDiagnostic("deadline", [], Map("TreeQuiesced", "true"), "1500")
	AssertContains(Fact, "elapsed_ms=unknown callbacks=0 tree_quiesced=unknown exit=unknown failure=unavailable")
	Fact := _UpdaterNativePartialStageDiagnostic("PRIVATE_KIND", [Map("exit", "1", "stdout", "PRIVATE_URL_TOKEN")], Map(), 0)
	AssertContains(Fact, "kind=unknown")
	AssertContains(Fact, "exit=unknown failure=invalid")
	AssertFalse(InStr(Fact, "PRIVATE"), "private stdout never enters the bounded scalar projection")
}
Test("updater native: missing partial stage exposes captured cause without weakening its assertion",
	(*) => _UpdaterNative_WithContract(_UpdaterNativePartialStageDiagnosticControls))

_UpdaterNativeEarlyStagingFactControls() {
	Empty := Map("type", "absent", "arity", 0, "size_available", "unavailable")
	Fact := Map("schema_version", 2, "operation", "not_file_read", "exception", "other",
		"expected", Empty, "actual", Empty, "observed_stage", "proxy_resolve",
		"exception_family", "invalid_operation", "hresult", -2146233079)
	AssertContains(_UpdaterNativeStagingDiagnosticFact(Fact),
		"observed_stage=proxy_resolve exception_family=invalid_operation hresult=-2146233079",
		"actual pre-read exception family and stage remain bounded scalars")
	Fact["hresult"] := "-2146233079"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(Fact), "string native codes are refused")
	Fact["hresult"] := -2146233079
	Fact["exception_family"] := "PRIVATE_MESSAGE"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(Fact), "unlisted exception text is refused")
	Fact["exception_family"] := "invalid_operation"
	Fact["observed_stage"] := "PRIVATE_URL"
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(Fact), "private stage values are refused")
	Fact["observed_stage"] := "proxy_resolve"
	Fact.Delete("hresult")
	AssertEqual("", _UpdaterNativeStagingDiagnosticFact(Fact), "partial extended facts are refused")
	Setup := Map("schema_version", 1, "site", "native_routes_load", "line", 30,
		"exception", "invalid_operation", "error", "compiler", "hresult", -2146233079)
	AssertEqual("site=native_routes_load line=30 exception=invalid_operation error=compiler hresult=-2146233079", _UpdaterNativeStagingSetupDiagnosticFact(Setup))
	for Pair in [["site", "PRIVATE_URL"], ["line", 8193], ["line", "30"], ["exception", "PRIVATE_ERROR"],
		["error", "PRIVATE_TOKEN"], ["hresult", 2147483648], ["schema_version", 2]] {
		Changed := Setup.Clone()
		Changed[Pair[1]] := Pair[2]
		AssertEqual("", _UpdaterNativeStagingSetupDiagnosticFact(Changed), "setup observations reject malformed private fields")
	}
	Setup["private"] := "PRIVATE"
	AssertEqual("", _UpdaterNativeStagingSetupDiagnosticFact(Setup))
}
Test("updater fixture: early staging diagnostics retain actual bounded operation provenance",
	_UpdaterNativeEarlyStagingFactControls)

_UpdaterNativeRefusedSidecarControls(Contract) {
	Directory := _SR_AcquireCaptureDirectory()
	Path := Directory . "sidecar.json"
	try {
		for Mode in ["valid", "invalid", "sink_refused"] {
			if FileExist(Path)
				FileDelete(Path)
			Text := Mode == "invalid" ? "PRIVATE_CONTENT" : '{"schema_version":2,"operation":"not_file_read","exception":"unauthorized","observed_stage":"file_remove","exception_family":"unauthorized","hresult":-2147024891,"expected":{"type":"absent","arity":0,"size_available":"unavailable"},"actual":{"type":"absent","arity":0,"size_available":"unavailable"}}'
			FileAppend(Text, Path, "UTF-8-RAW")
			Observed := []
			Printer := Mode == "sink_refused" ? _ManagedRemoteStateWaitPrinterRefused.Bind(Map("calls", 0)) : (Fact) => Observed.Push(Fact)
			Run := _UpdaterNativeRefusalDiagnosticControl(Printer)
			Run.StagingDiagnosticPath := Path
			Run.FixtureResult := Map("exit", 1, "stdout", '{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{}}')
			Caught := false
			try Run.Refused("download", "file_remove")
			catch as Failure {
				Caught := true
				AssertContains(Failure.Message, "expected: <file_remove>", "observation preserves the exact primary stage assertion")
			}
			AssertTrue(Caught)
			AssertEqual(Mode == "valid" ? "reported" : "unavailable", Run.StagingDiagnosticStatus)
			AssertEqual(Mode == "valid" ? 2 : Mode == "invalid" ? 1 : 0, Observed.Length)
			if Mode == "valid" {
				AssertContains(Observed[2], "observed_stage=file_remove exception_family=unauthorized hresult=-2147024891")
				AssertFalse(InStr(Observed[2], "PRIVATE"))
			}
		}
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		DirDelete(Directory, false)
	}
}
Test("updater native: refusal sidecar observation preserves the original stage assertion", _UpdaterNative_WithContract.Bind(_UpdaterNativeRefusedSidecarControls))

_UpdaterNativeRouteShapeControls() {
	; Independent literal receipt: no route, endpoint, URL or credential is copied.
	Text := '{"schema_version":1,"selection_kind":"hashtable","selection_arity":1,"ok_kind":"bool","ok_value":"false","routes_kind":"array","routes_count":0,"max_routes_kind":"absent","max_routes_value":-1,"max_redirects_kind":"absent","max_redirects_value":-1,"receipt_kind":"hashtable","receipt_count":4,"receipt_backend_kind":"string","receipt_stage_kind":"string"}'
	Fact := JsonParse(Text)
	AssertContains(_UpdaterNativeRouteShapeFact(Fact), "selection_kind=hashtable selection_arity=1 ok_kind=bool ok_value=false")
	AssertContains(_UpdaterNativeRouteShapeFact(Fact), "receipt_kind=hashtable receipt_count=4 receipt_backend_kind=string receipt_stage_kind=string")
	Fact["private"] := "PRIVATE_URL_TOKEN"
	AssertEqual("", _UpdaterNativeRouteShapeFact(Fact), "unknown/private shape fields are refused")
	Fact.Delete("private")
	Fact["selection_kind"] := "PRIVATE_URL_TOKEN"
	AssertEqual("", _UpdaterNativeRouteShapeFact(Fact), "unlisted kinds never reach scalar notices")
	Fact["selection_kind"] := "hashtable"
	Fact["max_routes_value"] := "8"
	AssertEqual("", _UpdaterNativeRouteShapeFact(Fact), "string policy values remain unavailable")
	Directory := _SR_AcquireCaptureDirectory()
	Path := Directory . "route-shape.json"
	try {
		FileAppend(Text, Path, "UTF-8-RAW")
		AssertContains(_UpdaterNativeReadRouteShape(Path), "routes_kind=array routes_count=0", "actual bounded sidecar joins the receiving validator")
		FileDelete(Path)
		FileAppend(StrReplace(Text, '"routes_count":0', '"routes_count":false'), Path, "UTF-8-RAW")
		AssertEqual("", _UpdaterNativeReadRouteShape(Path), "JSON booleans cannot masquerade as policy integer observations")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		DirDelete(Directory, false)
	}
}
Test("updater staging: closed route-shape observation preserves typed policy and private bounds", _UpdaterNativeRouteShapeControls)


_UpdaterNativeSetupDetailControls() {
	Fact := Map("schema_version", 1, "site", "download_module_load", "line", 7,
		"exception", "invalid_operation", "error", "compiler", "hresult", -2146233079,
		"command", "add_type", "category", "6", "language", "FullLanguage", "compiler", "CS1519")
	AssertContains(_UpdaterNativeStagingSetupDiagnosticFact(Fact), "command=add_type category=6 language=FullLanguage compiler=CS1519")
	for Pair in [["command", "PRIVATE_COMMAND"], ["category", "32"], ["category", 6],
		["language", "PRIVATE_LANGUAGE"], ["compiler", "CS15190"], ["command", "get_content"], ["error", "other"]] {
		Changed := Fact.Clone()
		Changed[Pair[1]] := Pair[2]
		AssertEqual("", _UpdaterNativeStagingSetupDiagnosticFact(Changed), "compiler details require exact direct provenance")
	}
	Fact.Delete("compiler")
	AssertEqual("", _UpdaterNativeStagingSetupDiagnosticFact(Fact), "partial detail sets are refused")
}
Test("updater fixture: setup details require direct closed compiler provenance", _UpdaterNativeSetupDetailControls)


_UpdaterNativeObservedSourceBudget() {
	global UPDATER_STAGING_ENV_MAX_CHARS, UPDATER_STAGING_MAX_SCRIPT_CHUNKS
	Original := _Updater_BuildStagingWorkerScript()
	Observed := _UpdaterNativeObservedStagingScript(Original)
	Payload := _Updater_EncodePowerShellCommand(Observed)
	AssertTrue(Ceil(StrLen(Payload) / UPDATER_STAGING_ENV_MAX_CHARS) <= UPDATER_STAGING_MAX_SCRIPT_CHUNKS,
		"the exact observed native worker fits the unchanged production transport bound")
	Transport := _Updater_BuildStagingTransport(Observed, _Updater_BuildSwapWorkerScript(),
		"https://fixture.invalid/staging", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"C:\fixture\new.exe", "C:\fixture\swap.ps1", "C:\fixture\current.exe", 524288, 5000)
	try AssertEqual(Observed, _UST_DecodeUtf16Base64(Transport.ScriptPayload),
		"the actual bounded environment transport preserves the full observed worker")
	finally _Updater_ClearStagingTransport(Transport)
}
Test("updater native: exact observed source fits unchanged encoded chunk transport", _UpdaterNativeObservedSourceBudget)

_UpdaterNativeObservedSourceLiteral() {
	Original := _Updater_BuildStagingWorkerScript()
	Observed := _UpdaterNativeObservedStagingScript(Original)
	Start := InStr(Observed, "$StagingSource=@'`n")
	AssertTrue(Start > 0, "the real constructor contains its quoted literal boundary")
	Start += StrLen("$StagingSource=@'`n")
	End := InStr(Observed, "`n'@`n", true, Start)
	AssertTrue(End > Start, "the real constructor has one complete literal")
	AssertEqual(Original, SubStr(Observed, Start, End - Start),
		"all production statements reach the observation transform without encoding duplication")
}
Test("updater native: literal fixture transport conserves every original source byte", _UpdaterNativeObservedSourceLiteral)

Test("updater native: a here-string closing delimiter cannot escape the source fixture", (*) =>
	AssertThrows(() => _UpdaterNativeObservedStagingScript("param()`n'@"),
		"a source delimiter must refuse before it can become surrounding PowerShell"))

Test("updater native: CR-only source delimiters cannot escape the literal fixture", (*) =>
	AssertThrows(() => _UpdaterNativeObservedStagingScript("param()`n# source`r'@`r$script:escaped=1"),
		"PowerShell CR boundaries refuse before any injected statement can execute"))
