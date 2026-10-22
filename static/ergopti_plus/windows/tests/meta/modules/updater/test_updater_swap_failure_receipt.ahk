; tests/meta/modules/updater/test_updater_swap_failure_receipt.ahk

; ==============================================================================
; MODULE: Updater Swap Failure Receipt Meta Test
; DESCRIPTION:
; Guards AHK-048: once the resident driver exits, the hidden swap worker is the
; only process that can preserve an exact replacement failure. The worker must
; publish a bounded single-use terminal before relaunching the old-good driver,
; and the next ready driver must visibly consume that receipt.
; ==============================================================================

#Requires AutoHotkey v2.0


; Returns the exit code of the real PowerShell parser over one file: 0 when the
; file parses without error.
_USFR_ParsePowerShellFile(Path) {
	ParserPath := A_Temp . "\ergopti-swap-receipt-parse-" . A_TickCount . ".ps1"
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

_USFR_DurableTerminalPrecedesRollbackRelaunch() {
	Script := FileRead(_Updater_SwapWorkerPath(), "UTF-8")
	Assert(Script != "", "the bundled swap worker must exist")
	WritePos := InStr(Script, "WriteTerminal $TerminalPath")
	EnvPos := InStr(Script, 'ERGOPTI_UPDATER_SWAP_TERMINAL', , Max(WritePos, 1))
	CanonicalRelaunchPos := InStr(Script,
		'$RestoredChild=StartReady $CurrentExe', , Max(EnvPos, 1))
	RecoveryRelaunchPos := InStr(Script,
		'$RecoveryChild=StartReady $Recovery', , Max(CanonicalRelaunchPos, 1))
	Assert(WritePos > 0 and EnvPos > WritePos
		and CanonicalRelaunchPos > EnvPos
		and RecoveryRelaunchPos > CanonicalRelaunchPos,
		"the exact durable terminal must be inherited by every old-good relaunch")
	Assert(InStr(Script, '[IO.File]::Move($Temp,$Path)') > 0,
		"the failure receipt must publish atomically instead of exposing partial text")
	AssertEqual(0, _USFR_ParsePowerShellFile(_Updater_SwapWorkerPath()),
		"the bundled durable-receipt swap worker must remain valid PowerShell")
}

Test("updater swap: rollback relaunch inherits an atomic failure receipt (updater-swap-failure-receipt-2026-08-28)",
	_USFR_DurableTerminalPrecedesRollbackRelaunch)

_USFR_NextReadyBootConsumesExactTerminal() {
	Source := _DriverSourceNoComments()
	Assert(Source != "", "the concatenated driver source must be readable")
	CapturePos := InStr(Source, "_UpdaterInheritedSwapFailurePath := EnvGet(")
	ClearPos := InStr(Source, 'try EnvSet("ERGOPTI_UPDATER_SWAP_TERMINAL", "")', , Max(CapturePos, 1))
	ReadyPos := InStr(Source, "_DriverReady := true", , Max(ClearPos, 1))
	ArmPos := InStr(Source, "`n_Updater_ArmInheritedSwapFailureNotice()`n", , Max(ReadyPos, 1))
	Assert(CapturePos > 0 and ClearPos > CapturePos
		and ReadyPos > ClearPos and ArmPos > ReadyPos,
		"boot must capture single-use authority early and surface it only after ready")

	Load := _UpdaterTest_ResolveFunction("_Updater_LoadSwapFailureTerminal")
	TempDir := A_Temp . "\ergopti-updater-swap-receipt-" . A_TickCount
	DirCreate(TempDir)
	ReceiptPath := TempDir . "\swap_update.ps1.log.terminal"
	try {
		FileAppend("SWAP_ERROR:Access to Current.exe was denied", ReceiptPath,
			"UTF-8-RAW")
		AssertEqual("SWAP_ERROR:Access to Current.exe was denied",
			Load.Call(ReceiptPath, ReceiptPath),
			"the next driver must recover the exact bounded worker terminal")
		AssertEqual("", Load.Call(ReceiptPath, ReceiptPath . ".other"),
			"an inherited path outside the authorized receipt must fail closed")
	} finally {
		try FileDelete(ReceiptPath)
		try DirDelete(TempDir)
	}
}

Test("updater boot: exact swap failure is consumed visibly after ready (updater-swap-failure-receipt-2026-08-28)",
	_USFR_NextReadyBootConsumesExactTerminal)
