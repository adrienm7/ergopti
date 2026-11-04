; tests/unit/modules/updater/test_updater_managed_transport_diagnostics.ahk

; ==============================================================================
; MODULE: Updater Managed Transport Fixture Diagnostics
; DESCRIPTION:
; The updater's native fixture diagnostics keep closed scalar shapes and
; privacy: staging, partial-stage, sidecar, route-shape and setup facts,
; and the literal source transport that conserves every byte.
; ==============================================================================

#Requires AutoHotkey v2.0





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


; The observed wrapper redeclares the bundled worker's one-line parameter block,
; so @PSBoundParameters forwards exactly what the -File worker would receive.
_UpdaterNativeObservedSourceHeader() {
	Original := FileRead(_Updater_StagingWorkerPath(), "UTF-8")
	Assert(RegExMatch(Original, "m)^param\(\[string\]\$TransportPrefix.*\)$", &Header),
		"the bundled staging worker declares its transport prefix parameter on one line")
	Observed := _UpdaterNativeObservedStagingScript(Original)
	AssertEqual(1, InStr(Observed, Header[0] . "`n"),
		"the observed wrapper starts with the exact bundled parameter declaration")
}
Test("updater native: observed wrapper forwards the bundled worker parameters", _UpdaterNativeObservedSourceHeader)

_UpdaterNativeObservedSourceLiteral() {
	Original := FileRead(_Updater_StagingWorkerPath(), "UTF-8")
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
