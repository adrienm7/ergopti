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
		Prefix := RegExReplace(Transport.Environment[1].Name, "_SCRIPT$")
		InheritedScriptPayload := EnvGet(Transport.Environment[1].Name)
		AssertEqual(Transport.ScriptChunkCount, Integer(EnvGet(Prefix . "_SCRIPT_COUNT")),
			"the native bootstrap must receive the exact source fragment count")
		Loop Transport.ScriptChunkCount - 1
			InheritedScriptPayload .= EnvGet(Prefix . "_SCRIPT_" . (A_Index + 1))
		AssertEqual(Transport.ScriptPayload, InheritedScriptPayload,
			"the exact encoded worker must be published under the bootstrap contract")
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


; ShellRunner combines stdout/stderr. Accept only the complete declared native
; receipt plus marker; unexpected output remains visible to the original oracle.
_UST_ReceiveNativeCmd(State, MultiChunk, ExitCode, Stdout, Stderr) {
	State.ExitCode := ExitCode
	State.Stdout := Stdout
	State.EnvironmentReceipt := Stderr
	if MultiChunk && Stderr == "" && RegExMatch(Stdout,
		"^ENV_UNITS:(\d+)\r?\n(TRANSPORT_OK)\z", &Receipt) {
		State.EnvironmentReceipt := "ENV_UNITS:" . Receipt[1]
		State.Stdout := Receipt[2]
	}
	State.Done := true
}

_UST_RealCmdEnvironmentRoundTrip(MultiChunk := false) {
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
	if MultiChunk {
		; Carry the actual production swap worker as UTF-8 data; never execute it.
		SwapScript := _Updater_BuildSwapWorkerScript() . "`n# é & 字"
		while StrLen(_Updater_EncodeUtf8Payload(SwapScript)) < UPDATER_STAGING_ENV_MAX_CHARS * 2 + 100
			SwapScript .= "`n# UTF-8 swap padding 0123456789abcdef"
		ExpectedSwapHash := CryptoSha256(SwapScript)
		Assert(RegExMatch(ExpectedSwapHash, "^[0-9a-f]{64}$"), "independent CNG swap digest must be available")
		Script := StrReplace(Script,
			'if ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SwapScriptPayload)) -cne "SWAP_PAYLOAD_OK") { throw "swap payload mismatch" }',
			'$swapBytes=[Convert]::FromBase64String($SwapScriptPayload);$sha=[Security.Cryptography.SHA256]::Create();try{if(([BitConverter]::ToString($sha.ComputeHash($swapBytes))).Replace("-","").ToLowerInvariant() -cne "' . ExpectedSwapHash . '"){throw "swap exact UTF-8 digest mismatch"}}finally{$sha.Dispose()}')
		; The output marker must occur after all padding: a lost source tail cannot pass.
		Script := StrReplace(Script, 'Write-Output "TRANSPORT_OK"', "")
		Script .= "`n" . '$environmentUnits=1;foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$environmentUnits+=$entry.Key.Length+$entry.Value.Length+2};[Console]::Error.WriteLine("ENV_UNITS:"+$environmentUnits)'
	}
	TargetPayloadSize := MultiChunk ? UPDATER_STAGING_ENV_MAX_CHARS * 2 + 100 : 6000
	while StrLen(_Updater_EncodePowerShellCommand(Script)) < TargetPayloadSize
		Script .= "`n# transport padding 0123456789abcdef0123456789abcdef"
	if MultiChunk
		Script .= "`n" . 'Write-Output "TRANSPORT_OK"'
	OnDone := _UST_ReceiveNativeCmd.Bind(State, MultiChunk)
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
		if !MultiChunk
			Assert(StrLen(Transport.ScriptPayload) <= UPDATER_STAGING_ENV_MAX_CHARS,
				"positive control: the real cmd probe must stay inside the production guard")
		else {
			AssertEqual(3, Transport.ScriptChunkCount, "actual cmd control must exercise three inherited fragments")
			Assert(Transport.SwapChunkCount >= 3, "actual cmd control must receive the production UTF-8 swap worker across at least three fragments")
			Assert(StrLen(Transport.ScriptPayload) > UPDATER_STAGING_ENV_MAX_CHARS * 2,
				"an unchunked predecessor cannot admit this actual high-water worker")
		}
		for Pair in Transport.Environment
			Assert(StrLen(Pair.Value) <= UPDATER_STAGING_ENV_MAX_CHARS,
				"every actual cmd inherited fragment retains the original guarded value bound")
		Worker := ShellRunner_SpawnTreeOwned(
			_Updater_PowerShellPath(), Transport.Args, OnDone)
		Assert(IsObject(Worker) and Worker.start(),
			"the exact ShellRunner transport must start through cmd.exe")
		_Updater_ClearStagingTransport(Transport)
		TransportCleared := true
		for Pair in Transport.Environment
			AssertEqual("", EnvGet(Pair.Name), "all exact staging inherited fragments must retire after actual child admission")
		SelectedTransportUnits := 1
		for Pair in Transport.Environment
			SelectedTransportUnits += StrLen(Pair.Name) + StrLen(Pair.Value) + 2
		Deadline := A_TickCount + 10000
		while (!State.Done and A_TickCount < Deadline)
			Sleep(25)
		Assert(State.Done,
			"cmd.exe must inherit the encoded transport before the parent clears it")
		AssertEqual(0, State.ExitCode,
			"the encoded worker must execute successfully through the inherited environment")
		AssertEqual("TRANSPORT_OK", State.Stdout,
			"cmd.exe must preserve the Unicode and metacharacter argv decoded by the bootstrap")
		if MultiChunk {
			Assert(RegExMatch(Trim(State.EnvironmentReceipt), "^ENV_UNITS:(\d+)$", &EnvironmentMatch),
				"the actual cmd child must report a numeric whole inherited environment high-water receipt")
			Assert(Integer(EnvironmentMatch[1]) >= SelectedTransportUnits,
				"whole inherited Unicode environment includes the exact complete selected transport")
			Assert(StrLen(Transport.ScriptPayload) >= StrLen(_Updater_EncodePowerShellCommand(_Updater_BuildStagingWorkerScript())),
				"native source high-water must cover the full current production staging payload")
		}
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

Test("Updater staging transport: real cmd executes the exact three-fragment source (updater-staging-transport)",
	_UST_RealCmdEnvironmentRoundTrip.Bind(true))

_UST_CombinedNativeReceiptRejectsExtraOutput() {
	Valid := {Done: false}
	_UST_ReceiveNativeCmd(Valid, true, 0, "ENV_UNITS:40037`r`nTRANSPORT_OK", "")
	AssertEqual("TRANSPORT_OK", Valid.Stdout, "actual merged receipt preserves the exact native output marker")
	AssertEqual("ENV_UNITS:40037", Valid.EnvironmentReceipt, "actual merged receipt retains its numeric environment units")
	for Raw in ["ENV_UNITS:40037`nTRANSPORT_OK`nprivate extra", "unexpected`nENV_UNITS:40037`nTRANSPORT_OK", "ENV_UNITS:bad`nTRANSPORT_OK", "ENV_UNITS:40037`nENV_UNITS:40037`nTRANSPORT_OK"] {
		Refused := {Done: false}
		_UST_ReceiveNativeCmd(Refused, true, 0, Raw, "")
		AssertEqual(Raw, Refused.Stdout, "undeclared output remains intact for the native exact-marker refusal")
		AssertEqual("", Refused.EnvironmentReceipt, "undeclared output cannot manufacture an aggregate receipt")
	}
	Separate := {Done: false}
	_UST_ReceiveNativeCmd(Separate, true, 0, "ENV_UNITS:40037`nTRANSPORT_OK", "unexpected")
	AssertEqual("ENV_UNITS:40037`nTRANSPORT_OK", Separate.Stdout, "foreign separate stderr cannot be hidden by protocol reception")
	Single := {Done: false}
	_UST_ReceiveNativeCmd(Single, false, 0, "TRANSPORT_OK", "")
	AssertEqual("TRANSPORT_OK", Single.Stdout, "original single-fragment native receiver stays exact")
}

Test("Updater staging transport: actual merged native receipt refuses undeclared output",
	_UST_CombinedNativeReceiptRejectsExtraOutput)
