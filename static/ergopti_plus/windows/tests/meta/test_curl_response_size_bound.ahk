; tests/meta/test_curl_response_size_bound.ahk
#Requires AutoHotkey v2.0

global _CRSB_READS := []
global _CRSB_FILES := Map()
global _CRSB_SIZES := Map()
global _CRSB_SHELL_RESULT := 0

_CRSB_Read(Path, Encoding := "") {
	global _CRSB_READS, _CRSB_FILES
	_CRSB_READS.Push(Path)
	return _CRSB_FILES.Get(Path, "")
}

_CRSB_Size(Path) {
	global _CRSB_SIZES
	return _CRSB_SIZES.Get(Path, 0)
}

_CRSB_TerminalBodyWaitsForReceiptAndSizeProof() {
	global _CRSB_READS, _CRSB_FILES, _CRSB_SIZES
	_CRSB_READS := []
	_CRSB_FILES := Map("status", "200", "exit", "", "body", "secret")
	_CRSB_SIZES := Map("body", 6)
	Pending := _LLM_CurlReadTerminal("status", "exit", "body", 4,
		_CRSB_Read, _CRSB_Size)
	AssertFalse(Pending["complete"])
	AssertFalse(Pending["body_read"],
		"a growing curl body must not be materialized before the terminal receipt")
	AssertFalse(_CRSB_ArrayHas(_CRSB_READS, "body"),
		"the pre-terminal poll must not call FileRead on the response body")

	_CRSB_READS := []
	_CRSB_FILES["exit"] := "0"
	Oversize := _LLM_CurlReadTerminal("status", "exit", "body", 4,
		_CRSB_Read, _CRSB_Size)
	AssertTrue(Oversize["complete"])
	AssertTrue(Oversize["oversize"])
	AssertFalse(Oversize["body_read"])
	AssertFalse(_CRSB_ArrayHas(_CRSB_READS, "body"),
		"an oversized response must be rejected from FileGetSize without allocating its body")
}

_CRSB_ArrayHas(Values, Needle) {
	for Value in Values {
		if Value == Needle
			return true
	}
	return false
}

_CRSB_CaptureShellResult(ExitCode, Stdout, Stderr) {
	global _CRSB_SHELL_RESULT
	_CRSB_SHELL_RESULT := Map("exit", ExitCode, "stdout", Stdout)
}

_CRSB_TreeCollectorRejectsOversizeWithoutPayload() {
	global _CRSB_SHELL_RESULT
	Path := A_Temp . "\ergopti_ahk053_shell_bound.tmp"
	try {
		AssertTrue(FSWrite(Path, "123456"))
		_CRSB_SHELL_RESULT := 0
		_SR_TreeFinishClaim(Map(
			"NativeErrors", [],
			"TaskId", 53001,
			"TmpFile", Path,
			"MaxOutputBytes", 4,
			"ExitCode", 0,
			"OnDone", _CRSB_CaptureShellResult))
		AssertTrue(_CRSB_SHELL_RESULT is Map)
		AssertEqual(63, _CRSB_SHELL_RESULT["exit"],
			"the collector must surface curl's max-filesize terminal class")
		AssertEqual("", _CRSB_SHELL_RESULT["stdout"],
			"an oversized temp body must never reach the completion callback")
		AssertFalse(FileExist(Path),
			"the rejected oversized temp body must still be cleaned up")
	} finally {
		try FSDelete(Path)
	}
}

_CRSB_EveryCurlTransportDeclaresTheCap() {
	Http := FileRead(A_ScriptDir . "\..\adapters\http_client.ahk", "UTF-8")
	Shell := FileRead(A_ScriptDir . "\..\adapters\shell_runner.ahk", "UTF-8")
	Remote := FileRead(A_ScriptDir . "\..\modules\llm\api_remote.ahk", "UTF-8")
	OllamaHttp := FileRead(A_ScriptDir
		. "\..\modules\llm\api_ollama\ollama_http.ahk", "UTF-8")
	OllamaStreaming := FileRead(A_ScriptDir
		. "\..\modules\llm\api_ollama\ollama_streaming.ahk", "UTF-8")
	Assert(InStr(Http, '"max-filesize = " . HTTP_CURL_MAX_RESPONSE_BYTES') > 0,
		"CurlAsyncRequest must stop curl at the shared response byte ceiling")
	Assert(InStr(Http, "HTTP_CURL_MAX_RESPONSE_BYTES") > 0
		and InStr(Shell, '"MaxOutputBytes"') > 0,
		"the tree-owned stdout collector must receive and enforce the same ceiling")
	Finish := _DriverFuncBody("_SR_TreeFinishClaim")
	Assert(InStr(Finish, "FileGetSize(") > 0
		and InStr(Finish, "FileGetSize(") < InStr(Finish, "FileRead("),
		"the collector must reject by file size before materializing stdout")
	Assert(InStr(Remote, "_LLM_CurlMaxFileSizeArg()") > 0,
		"custom remote generation must pass curl the shared response ceiling")
	Assert(InStr(OllamaHttp, "_LLM_CurlMaxFileSizeArg()") > 0
		and InStr(OllamaStreaming, "_LLM_CurlMaxFileSizeArg()") > 0,
		"every sibling LLM curl transport must share the response ceiling")
}

_CRSB_CurlRuntimeLimitRequiresModernCurl() {
	LegacyVersion(*) => "8.3.0"
	MinimumVersion(*) => "8.4.0"
	ModernVersion(*) => "8.19.0.0"
	MalformedVersion(*) => "unknown"
	AssertFalse(_HTTP_CurlRuntimeLimitSupported("curl.exe", LegacyVersion),
		"curl before 8.4 cannot enforce max-filesize while receiving an unknown-length body")
	AssertTrue(_HTTP_CurlRuntimeLimitSupported("curl.exe", MinimumVersion),
		"curl 8.4 is the first version with a runtime max-filesize check")
	AssertTrue(_HTTP_CurlRuntimeLimitSupported("curl.exe", ModernVersion),
		"newer four-component Windows file versions must remain supported")
	AssertFalse(_HTTP_CurlRuntimeLimitSupported("curl.exe", MalformedVersion),
		"an unparseable curl version must fail closed")
	AssertThrows(() => _LLM_CurlMaxFileSizeArg("curl.exe", LegacyVersion),
		"a direct LLM curl command must refuse an unsafe runtime")
	Assert(InStr(_LLM_CurlMaxFileSizeArg("curl.exe", ModernVersion),
		"--max-filesize") > 0,
		"a supported direct LLM curl command must retain the shared byte ceiling")

	LimitArg := _DriverFuncBody("_LLM_CurlMaxFileSizeArg")
	Assert(InStr(LimitArg, "_HTTP_CurlRuntimeLimitSupported") > 0,
		"every direct LLM curl command must cross the shared runtime-capability gate")
}

Test("curl: terminal body is receipt-gated and size-bounded (AHK-053)",
	_CRSB_TerminalBodyWaitsForReceiptAndSizeProof)
Test("curl: tree collector rejects oversized stdout before callback (AHK-053)",
	_CRSB_TreeCollectorRejectsOversizeWithoutPayload)
Test("curl: every transport enforces one response byte ceiling (AHK-053)",
	_CRSB_EveryCurlTransportDeclaresTheCap)
Test("curl: legacy versions cannot bypass the live response ceiling (AHK-071)",
	_CRSB_CurlRuntimeLimitRequiresModernCurl)
