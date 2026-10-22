; tests/unit/modules/updater/test_updater_staging_transport.ahk

; ==============================================================================
; MODULE: Updater Staging Transport Contract
; DESCRIPTION:
; The updater runs two bundled, readable PowerShell workers with -File: the
; staging worker (download and digest check) and the swap worker (executable
; replacement). Release data travels as inherited environment values named by
; one prefix argument, so it stays data, never PowerShell source, and the
; cmd.exe wrapper of ShellRunner cannot expand or split it.
;
; Antivirus sandboxes scored the former transport as a malware stage: Base64
; code in environment variables, decoded and compiled with a ScriptBlock and
; launched through -EncodedCommand (updater-av-surface-2026-10-22). These
; tests fail if any driver code path launches an encoded command again.
; ==============================================================================

#Requires AutoHotkey v2.0

_UST_Digest() => "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

; Returns the exit code of the real PowerShell parser over one file: 0 when the
; file parses without error.
_UST_ParsePowerShellFile(Path) {
	ParserPath := A_Temp . "\ergopti-staging-parse-" . A_TickCount . ".ps1"
	try {
		FileAppend('param([string]$Path)' . "`n"
			. '$Errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$Errors)' . "`n"
			. 'if($Errors.Count -ne 0){exit 3};exit 0' . "`n", ParserPath, "UTF-8-RAW")
		return RunWait(_Updater_QuoteCreateProcessArg(_Updater_PowerShellPath())
			. " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "
			. _Updater_QuoteCreateProcessArg(ParserPath) . " -Path "
			. _Updater_QuoteCreateProcessArg(Path), , "Hide")
	} finally {
		try FileDelete(ParserPath)
	}
}

_UST_BuilderLaunchesBundledWorkerWithFile() {
	global _UpdaterStagingTransportCounter
	SavedCounter := _UpdaterStagingTransportCounter
	Transport := _Updater_BuildStagingTransport(
		_Updater_StagingWorkerPath(), _Updater_SwapWorkerPath(),
		"https://example.invalid/ErgoptiPlus.exe", _UST_Digest(),
		"C:\Temp\ErgoptiPlus_new.exe", "C:\Temp\swap_update.ps1",
		"C:\Program Files\ErgoptiPlus.exe", 1024, 30000)
	try {
		Assert(RegExMatch(Transport.Prefix, "\AERGOPTI_UPDATER_[0-9]+_[0-9]+_[0-9]+\z"),
			"the transport prefix is a private unique environment namespace")
		Expected := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", _Updater_StagingWorkerPath(), "-TransportPrefix", Transport.Prefix]
		AssertEqual(Expected.Length, Transport.Args.Length,
			"the staging launch is exactly the bundled worker with its prefix")
		for Arg in Expected
			AssertEqual(Arg, Transport.Args[A_Index], "staging argument " . A_Index)
		Values := Map("_URL", "https://example.invalid/ErgoptiPlus.exe",
			"_DIGEST", _UST_Digest(), "_NEW_EXE", "C:\Temp\ErgoptiPlus_new.exe",
			"_SWAP_PATH", "C:\Temp\swap_update.ps1", "_SWAP_SOURCE", _Updater_SwapWorkerPath(),
			"_CURRENT", "C:\Program Files\ErgoptiPlus.exe", "_MINIMUM", "1024", "_TIMEOUT", "30000")
		for Pair in Transport.Environment {
			Suffix := SubStr(Pair.Name, StrLen(Transport.Prefix) + 1)
			AssertEqual(Transport.Prefix, SubStr(Pair.Name, 1, StrLen(Transport.Prefix)),
				"every inherited value lives under the private prefix")
			Assert(!RegExMatch(Suffix, "\A_(?:SCRIPT|SWAP_[0-9]|SWAP_COUNT)"),
				"no inherited value carries worker source: " . Pair.Name)
			if Values.Has(Suffix)
				AssertEqual(Values[Suffix], EnvGet(Pair.Name), "inherited " . Suffix)
		}
		for Suffix in Values
			AssertEqual(Values[Suffix], EnvGet(Transport.Prefix . Suffix), "published " . Suffix)
	} finally {
		_Updater_ClearStagingTransport(Transport)
		_UpdaterStagingTransportCounter := SavedCounter
	}
	for Pair in Transport.Environment
		AssertEqual("", EnvGet(Pair.Name), "the parent retires every inherited value")
}

Test("Updater staging transport: the bundled worker runs with -File and a data-only environment (updater-av-surface-2026-10-22)",
	_UST_BuilderLaunchesBundledWorkerWithFile)


_UST_ReceiveProbe(State, ExitCode, Stdout, Stderr) {
	State.ExitCode := ExitCode
	State.Stdout := Trim(Stdout, "`r`n ")
	State.Stderr := Stderr
	State.Done := true
}

; Runs a probe worker through the exact production argv and ShellRunner's
; cmd.exe wrapper. Values carry cmd.exe metacharacters, non-ASCII text and a
; %VAR% reference that cmd.exe would expand if it were an argument.
_UST_RealCmdEnvironmentRoundTrip(CompilerControl := false) {
	global _UpdaterStagingTransportCounter
	SavedCounter := _UpdaterStagingTransportCounter
	Directory := A_Temp . "\ergopti-staging-transport-" . A_TickCount
	DirCreate(Directory)
	Probe := Directory . "\probe.ps1"
	Transport := 0
	Worker := 0
	State := { Done: false, ExitCode: -1, Stdout: "", Stderr: "" }
	NewExe := "C:\Temp\ergopti é&x %USERNAME%\ErgoptiPlus_new.exe"
	CurrentExe := "C:\Program Files\Ergopti é&x\ErgoptiPlus.exe"
	Source := 'param([string]$TransportPrefix)' . "`n"
		. '$ErrorActionPreference="Stop"' . "`n"
		. 'function V($Name){[Environment]::GetEnvironmentVariable($TransportPrefix+"_"+$Name)}' . "`n"
		. 'if ((V "URL") -cne "https://example.invalid/a&b/ErgoptiPlus.exe") { throw "URL mismatch" }' . "`n"
		. 'if ((V "DIGEST") -cne "' . _UST_Digest() . '") { throw "digest mismatch" }' . "`n"
		. 'if ((V "NEW_EXE") -cne "' . NewExe . '") { throw "new path mismatch" }' . "`n"
		. 'if ((V "CURRENT") -cne "' . CurrentExe . '") { throw "current path mismatch" }' . "`n"
		. 'if ((V "MINIMUM") -cne "1024") { throw "minimum mismatch" }' . "`n"
	if CompilerControl
		Source .= 'Add-Type -TypeDefinition "public static class ErgoptiStagingCompilerEnvironmentProbe { public static int Value = 19; }" -ErrorAction Stop;if([ErgoptiStagingCompilerEnvironmentProbe]::Value -ne 19){throw "Actual framework compiler result refused"}' . "`n"
	Source .= 'Write-Output "TRANSPORT_OK"' . "`n"
	try {
		; UTF-8 with BOM: Windows PowerShell reads a BOM-less script as ANSI.
		FileAppend(Source, Probe, "UTF-8")
		Transport := _Updater_BuildStagingTransport(Probe, _Updater_SwapWorkerPath(),
			"https://example.invalid/a&b/ErgoptiPlus.exe", _UST_Digest(),
			NewExe, "C:\Temp\ergopti é&x\swap_update.ps1", CurrentExe, 1024, 30000)
		Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Transport.Args,
			_UST_ReceiveProbe.Bind(State))
		Assert(IsObject(Worker) and Worker.start(),
			"the exact ShellRunner transport must start through cmd.exe")
		_Updater_ClearStagingTransport(Transport)
		for Pair in Transport.Environment
			AssertEqual("", EnvGet(Pair.Name), "inherited values retire after actual child admission")
		Deadline := A_TickCount + 20000
		while (!State.Done and A_TickCount < Deadline)
			Sleep(25)
		Assert(State.Done, "cmd.exe must inherit the transport before the parent clears it")
		AssertEqual(0, State.ExitCode,
			"the -File worker must read every value unchanged: " . State.Stdout . State.Stderr)
		AssertEqual("TRANSPORT_OK", State.Stdout,
			"cmd.exe must preserve Unicode, metacharacters and %VAR% text in the inherited data")
	} finally {
		_Updater_ClearStagingTransport(Transport)
		if IsObject(Worker)
			Worker.terminate()
		_UpdaterStagingTransportCounter := SavedCounter
		try DirDelete(Directory, true)
	}
}

Test("Updater staging transport: real cmd environment round-trip (updater-staging-transport)",
	_UST_RealCmdEnvironmentRoundTrip)

Test("Updater staging transport: the -File environment permits the actual framework compiler (updater-consumed-compiler-env)",
	_UST_RealCmdEnvironmentRoundTrip.Bind(true))


; The real bundled worker refuses a launch whose transport is not its own before
; it loads a module, opens a request or touches a file.
_UST_RealWorkerRefusesForeignTransport() {
	for Prefix in ["", "ERGOPTI_UPDATER_1_2", "ERGOPTI_UPDATER_1_2_3"] {
		State := { Done: false, ExitCode: -1, Stdout: "", Stderr: "" }
		Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", _Updater_StagingWorkerPath()]
		if Prefix != ""
			Args.Push("-TransportPrefix", Prefix)
		; The last prefix is well formed but publishes nothing: the URL is refused.
		EnvSet(Prefix . "_URL", "")
		Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
			_UST_ReceiveProbe.Bind(State))
		try {
			Assert(IsObject(Worker) and Worker.start(), "the bundled staging worker starts")
			Deadline := A_TickCount + 20000
			while (!State.Done and A_TickCount < Deadline)
				Sleep(25)
			Assert(State.Done, "the refused staging worker exits")
			Assert(State.ExitCode != 0, "a foreign or empty transport is refused: " . Prefix)
			Assert(!InStr(State.Stdout, "READY"), "a refused transport never reports READY")
			Assert(InStr(State.Stdout . State.Stderr,
				Prefix == "ERGOPTI_UPDATER_1_2_3" ? "Staging input URL was refused" : "Staging transport prefix was refused"),
				"the refusal names its reason: " . State.Stdout . State.Stderr)
		} finally {
			if IsObject(Worker)
				Worker.terminate()
		}
	}
}

Test("Updater staging transport: the bundled worker refuses a foreign transport (updater-av-surface-2026-10-22)",
	_UST_RealWorkerRefusesForeignTransport)


_UST_BundledWorkersParseAndCarryNoEncodedStage() {
	for Path in [_Updater_StagingWorkerPath(), _Updater_SwapWorkerPath(),
		_VendorDir . "\ergopti_crash_fallback_worker.ps1"] {
		Source := FileRead(Path, "UTF-8")
		Assert(Source != "", "bundled worker exists: " . Path)
		for Needle in ["-EncodedCommand", "ScriptBlock]::Create", "FromBase64String", "Invoke-Expression"]
			Assert(!InStr(Source, Needle), "bundled worker " . Path . " must not contain " . Needle)
		AssertEqual(0, _UST_ParsePowerShellFile(Path), "bundled worker parses: " . Path)
	}
}

Test("Updater staging transport: bundled workers parse and carry no encoded stage (updater-av-surface-2026-10-22)",
	_UST_BundledWorkersParseAndCarryNoEncodedStage)


; The compiled exe embeds this source as plain text that proxies and antivirus
; engines scan; tools/ci/windows-exe-av-surface.json forbids the same patterns
; in the built artifact.
_UST_DriverLaunchesNoEncodedCommand() {
	Source := _DriverSourceNoComments()
	Assert(Source != "", "the driver source must be readable")
	for Needle in ["-EncodedCommand", "ScriptBlock]::Create", "FromBase64String"]
		Assert(!InStr(Source, Needle), "driver code must not contain " . Needle
			. ": run a bundled script with -File and pass data, not code")
}

Test("Updater staging transport: no driver code launches an encoded PowerShell stage (updater-av-surface-2026-10-22)",
	_UST_DriverLaunchesNoEncodedCommand)


_UST_ProductionLaunchesOnlyBundledWorkers() {
	Body := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(InStr(Body, "_Updater_StagingWorkerPath()") > 0
		and InStr(Body, "_Updater_SwapWorkerPath()") > 0
		and InStr(Body, "_Updater_BuildStagingTransport(") > 0
		and InStr(Body, "Transport.Args") > 0,
		"production staging must launch the bundled worker through the transport builder")
	Assert(InStr(Body, "FileExist(WorkerPath)") > 0,
		"a missing bundled worker must fail before any launch")
	Assert(InStr(Body, "ShellRunner_SpawnTreeOwned") > 0
		and !RegExMatch(Body, "\bShellRunner_Spawn\("),
		"production staging must bind the exact process-tree owner, never the PID-only runner")
	Assert(InStr(Body, "_Updater_PowerShellPath()") > 0
		and InStr(Body, '"powershell.exe"') = 0,
		"production staging must resolve System32 PowerShell explicitly instead of searching the driver CWD")
	Swap := _DriverFuncBody("_Updater_CreateSuspendedSwapOwner")
	Assert(InStr(Swap, '"-File", SwapScriptPath') > 0,
		"the swap worker copy runs with -File")
	Fallback := _DriverFuncBody("_CrashReportWorkerFallbackArgs")
	Assert(InStr(Fallback, '"-File", _VendorDir . "\ergopti_crash_fallback_worker.ps1"') > 0,
		"the crash-report minimal writer runs its bundled script with -File")
}

Test("Updater staging transport: production launches only bundled -File workers (updater-av-surface-2026-10-22)",
	_UST_ProductionLaunchesOnlyBundledWorkers)
