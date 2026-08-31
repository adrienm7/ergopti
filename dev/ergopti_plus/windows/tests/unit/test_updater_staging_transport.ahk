; tests/unit/test_updater_staging_transport.ahk

; ==============================================================================
; MODULE: Updater Staging Transport Contract
; DESCRIPTION:
; The staging worker is intentionally multi-line, while ShellRunner's cmd.exe
; transport rejects every CR/LF-bearing argument. The updater must carry the
; exact script through inherited encoded data and pass only a single-line
; PowerShell bootstrap to ShellRunner.
; ==============================================================================

#Requires AutoHotkey v2.0

_UST_DecodeUtf16Base64(Payload) {
	Bytes := CryptoBase64Decode(Payload)
	if Bytes.Size == 0
		return ""
	return StrGet(Bytes.Ptr, Bytes.Size // 2, "UTF-16")
}

_UST_DecodeUtf8Base64(Payload) {
	Bytes := CryptoBase64Decode(Payload)
	if Bytes.Size == 0
		return ""
	return StrGet(Bytes.Ptr, Bytes.Size, "UTF-8")
}

_UST_FirstMultilineArg(Args) {
	for Arg in Args {
		if (InStr(Arg, "`n") or InStr(Arg, "`r"))
			return A_Index
	}
	return 0
}

_UST_ExactBuilderOutputCrossesShellRunnerConstraint() {
	global _UpdaterStagingTransportCounter, UPDATER_STAGING_ENV_MAX_CHARS
	SavedCounter := _UpdaterStagingTransportCounter
	Script := _Updater_BuildStagingWorkerScript()
	SwapScript := _Updater_BuildSwapWorkerScript()
	Assert(InStr(Script, "`n") > 0,
		"positive control: the real staging worker must exercise the multi-line payload constraint")
	Transport := _Updater_BuildStagingTransport(
		Script,
		SwapScript,
		"https://example.invalid/ErgoptiPlus.exe",
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"C:\Temp\ErgoptiPlus_new.exe",
		"C:\Temp\swap_update.ps1",
		"C:\Program Files\ErgoptiPlus.exe",
		1024,
		30000)
	try {
		AssertEqual(0, _UST_FirstMultilineArg(Transport.Args),
			"the exact updater args must satisfy ShellRunner's no-CR/LF contract")
		AssertEqual("-EncodedCommand", Transport.Args[5],
			"PowerShell must receive the single-line bootstrap through -EncodedCommand")
		AssertEqual(Script, _UST_DecodeUtf16Base64(Transport.ScriptPayload),
			"the environment payload must round-trip the exact generated staging script")
		AssertEqual(SwapScript, _UST_DecodeUtf8Base64(Transport.SwapScriptPayload),
			"the separate UTF-8 environment payload must round-trip the exact generated swap script")
		AssertEqual(Transport.Bootstrap,
			_UST_DecodeUtf16Base64(Transport.Args[6]),
			"the command-line payload must round-trip the exact bootstrap")
		AssertEqual(Transport.ScriptPayload,
			EnvGet(Transport.Environment[1].Name),
			"the exact encoded worker must be published under the bootstrap contract")
		Prefix := RegExReplace(Transport.Environment[1].Name, "_SCRIPT$")
		InheritedSwapPayload := ""
		Loop Transport.SwapChunkCount
			InheritedSwapPayload .= EnvGet(Prefix . "_SWAP_" . A_Index)
		AssertEqual(Transport.SwapScriptPayload, InheritedSwapPayload,
			"the exact UTF-8 swap worker must round-trip its bounded inherited chunks")
		for Pair in Transport.Environment
			Assert(StrLen(Pair.Value) <= UPDATER_STAGING_ENV_MAX_CHARS,
				"every inherited value must stay inside the guarded environment limit")

		RawArgs := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-Command", Script]
		AssertEqual(6, _UST_FirstMultilineArg(RawArgs),
			"mutation control: the former raw -Command worker violates the adapter contract")
	} finally {
		_Updater_ClearStagingTransport(Transport)
		_UpdaterStagingTransportCounter := SavedCounter
	}
}

Test("Updater staging transport: exact worker uses adapter-safe encoding (updater-staging-transport)",
	_UST_ExactBuilderOutputCrossesShellRunnerConstraint)

_UST_RealCmdEnvironmentRoundTrip() {
	global _UpdaterStagingTransportCounter, UPDATER_STAGING_ENV_MAX_CHARS
	SavedCounter := _UpdaterStagingTransportCounter
	Transport := 0
	TransportCleared := false
	Worker := 0
	State := { Done: false, ExitCode: -1, Stdout: "" }
	SwapScript := "SWAP_PAYLOAD_OK"
	Script := 'param([string]$Url, [string]$ExpectedSha256, [string]$NewExe, [string]$SwapScriptPath, [string]$CurrentExe, [int64]$MinimumSize, [int]$TimeoutMs, [string]$SwapScriptPayload)'
		. "`n" . 'if ($Url -cne "https://example.invalid/a&b/ErgoptiPlus.exe") { throw "URL mismatch" }'
		. "`n" . 'if ($ExpectedSha256 -cne "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") { throw "digest mismatch" }'
		. "`n" . 'if ($NewExe -cne "C:\Temp\ergopti é&x\ErgoptiPlus_new.exe") { throw "new path mismatch" }'
		. "`n" . 'if ($CurrentExe -cne "C:\Program Files\Ergopti é&x\ErgoptiPlus.exe") { throw "current path mismatch" }'
		. "`n" . 'if ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SwapScriptPayload)) -cne "SWAP_PAYLOAD_OK") { throw "swap payload mismatch" }'
		. "`n" . 'Write-Output "TRANSPORT_OK"'
	; Exercise the real high-water contract. A tiny EnvGet-only probe can pass
	; even if cmd.exe silently drops a production-sized inherited value.
	while StrLen(_Updater_EncodePowerShellCommand(Script)) < 6000
		Script .= "`n# transport padding 0123456789abcdef0123456789abcdef"
	OnDone := (ExitCode, Stdout, Stderr) => (
		State.ExitCode := ExitCode,
		State.Stdout := Stdout,
		State.Done := true)
	try {
		Transport := _Updater_BuildStagingTransport(
			Script,
			SwapScript,
			"https://example.invalid/a&b/ErgoptiPlus.exe",
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			"C:\Temp\ergopti é&x\ErgoptiPlus_new.exe",
			"C:\Temp\ergopti é&x\swap_update.ps1",
			"C:\Program Files\Ergopti é&x\ErgoptiPlus.exe",
			1024,
			30000)
		Assert(StrLen(Transport.ScriptPayload) <= UPDATER_STAGING_ENV_MAX_CHARS,
			"positive control: the real cmd probe must stay inside the production guard")
		Worker := ShellRunner_SpawnTreeOwned(
			_Updater_PowerShellPath(), Transport.Args, OnDone)
		Assert(IsObject(Worker) and Worker.start(),
			"the exact ShellRunner transport must start through cmd.exe")
		_Updater_ClearStagingTransport(Transport)
		TransportCleared := true
		Deadline := A_TickCount + 10000
		while (!State.Done and A_TickCount < Deadline)
			Sleep(25)
		Assert(State.Done,
			"cmd.exe must inherit the encoded transport before the parent clears it")
		AssertEqual(0, State.ExitCode,
			"the encoded worker must execute successfully through the inherited environment")
		AssertEqual("TRANSPORT_OK", State.Stdout,
			"cmd.exe must preserve the Unicode and metacharacter argv decoded by the bootstrap")
	} finally {
		if !TransportCleared
			_Updater_ClearStagingTransport(Transport)
		if IsObject(Worker)
			Worker.terminate()
		_UpdaterStagingTransportCounter := SavedCounter
	}
}

Test("Updater staging transport: real cmd environment round-trip (updater-staging-transport)",
	_UST_RealCmdEnvironmentRoundTrip)

_UST_ProductionNeverPassesRawWorkerToCommand() {
	Body := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(Body != "", "_Updater_StartStagingWorker must exist in the driver source")
	Assert(InStr(Body, "_Updater_BuildStagingTransport") > 0
		and InStr(Body, "_Updater_BuildSwapWorkerScript") > 0
		and InStr(Body, "Transport.Args") > 0,
		"production staging must launch only the encoded transport returned by its builder")
	Assert(InStr(Body, "ShellRunner_SpawnTreeOwned") > 0
		and !RegExMatch(Body, "\bShellRunner_Spawn\("),
		"production staging must bind the exact process-tree owner, never the PID-only runner")
	Assert(InStr(Body, "_Updater_PowerShellPath()") > 0
		and InStr(Body, '"powershell.exe"') = 0,
		"production staging must resolve System32 PowerShell explicitly instead of searching the driver CWD")
	Assert(InStr(Body, '"-Command", Script') = 0,
		"the multi-line worker must never return to ShellRunner as a raw -Command argument")
}

Test("Updater staging transport: production passes no raw multiline worker (updater-staging-transport)",
	_UST_ProductionNeverPassesRawWorkerToCommand)
