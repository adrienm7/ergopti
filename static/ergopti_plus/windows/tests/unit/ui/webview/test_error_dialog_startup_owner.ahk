; tests/unit/ui/webview/test_error_dialog_startup_owner.ahk

; ==============================================================================
; MODULE: Error Dialog Startup Cancellation Tests
; DESCRIPTION:
; Real logger policy and timers open native windows and collect phase-A reports.
; Only the existing SDK environment factory is controlled; vendored create/await
; remains real. This component assumes a ready resident, not a completed boot.
; ==============================================================================

#Requires AutoHotkey v2.0

_EDOT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_EDOT_Generated(Symbol) {
	global _DriverDir
	Found := ""
	loop files _DriverDir . "\_generated\*.ahk" {
		Text := FSReadStrict(A_LoopFileFullPath), Code := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&Code, Symbol)
		if Count {
			AssertTrue(Count == 1 && Found == "", "The generated symbol needs one complete owner: " . Symbol)
			Found := A_LoopFileFullPath
		}
	}
	AssertTrue(Found != "", "The canonical generated owner must exist: " . Symbol)
	return Found
}

_EDOT_Source(Root) {
	global _DriverDir, _SharedDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "global _EDOS_Root := " . _EDOT_Quote(Root) . "`n"
		. "global _SharedDir := " . _EDOT_Quote(Root . "\shared") . "`n"
		. "global _VendorDir := " . _EDOT_Quote(Root . "\vendor") . "`n"
		. "global _ConfigDir := " . _EDOT_Quote(Root . "\config\") . "`n"
		. "global _LogsDir := " . _EDOT_Quote(Root . "\logs\") . "`n"
		. "global ConfigurationFile := " . _EDOT_Quote(Root . "\config\absent.toml") . "`n"
		. 'global _AhkSubDir := "autohotkey\", _ALTGR_KANA_FIXUP := false' . "`n"
	for Vendor in ["Promise.ahk", "ComVar.ahk", "WebView2.ahk"]
		Source .= "#Include " . _DriverDir . "\vendor\" . Vendor . "`n"
	for Symbol in ["AppDirsFolderName", "WindowTitle", "LoggerSubFilesData", "UpdateChannelRegistryData", "UpdateScheduleData"]
		Source .= "#Include " . _EDOT_Generated(Symbol) . "`n"
	Owners := Map()
	for Symbol in ["JsonStringLiteral", "CryptoSha256Bytes", "FSReadBytesStrict", "HTTPIsValidUtf8", "WallClockTimestamp", "TickElapsed64",
		"_LoggerPrivacyConfig", "ErrorPolicy_Decide", "ManifestFindEntryByPath", "ConfigBindingIdentityTapPublication", "TapKeyBindingId",
		"IsCategoryGated", "IniCacheGet", "Gui_Create", "t", "UpdateChannels_Ids", "UpdateSchedule_Timing", "Updater_CurrentVersion",
		"CrashReport_Dir", "DiagSnapshot_ResolveCommit", "KS_IsDown", "HealthCheck_Config", "_HealthCheck_Paths",
		"ErrorReport_Compose", "IssueReport_Markdown", "Redact_Apply", "WebView_SharedEnvironment", "ErrorDialog_Init"] {
		OwnerRoot := Symbol == "ConfigBindingIdentityTapPublication" ? _SharedDir : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, OwnerRoot)
		AssertTrue(Owner != "", "The error child requires its genuine whole owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Source .= "#Include " . Owner . "`n"
		}
	}
	Source .= "#Include " . _DriverDir . "\infra\bundle.ahk`n"
	return Chr(0xFEFF) . Source . "#Include " . _DriverDir . "\tests\fixtures\error_dialog_startup_owner_body.ahk`n"
}

_EDOT_Assets(Root) {
	global _SharedDir
	for Subdir in ["config", "logs", "vendor\64bit", "shared\modules\diagnostics", "shared\modules\updater", "shared\data\locales"]
		FSCreateDirectoryExclusiveStrict(Root . "\" . Subdir)
	for Relative in ["modules\diagnostics\schema.json", "modules\diagnostics\redaction.json", "modules\diagnostics\issue_templates.json",
		"modules\diagnostics\error_policy.json", "modules\diagnostics\recent_issues.json", "modules\updater\defaults.json",
		"data\locales\en.json", "data\locales\fr.json"] {
		Original := _SharedDir . "\" . Relative, Copy := Root . "\shared\" . Relative
		FileCopy(Original, Copy, false)
		AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(Original)), CryptoSha256Bytes(FSReadBytesStrict(Copy)),
			"Private report inputs must remain canonical: " . Relative)
	}
	AssertTrue(FSWriteCreateDurable(Root . "\vendor\64bit\WebView2Loader.dll", "passive SDK factory availability marker"))
}

_EDOT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_EDOT_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "A previous unretired child prevents another component")
	Root := A_Temp . "\ergopti_error_startup_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_EDOT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _EDOT_Source(Root)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _EDOT_Done.Bind(State))
		AssertTrue(Handle.start(), "The exact error component must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The error dialog child did not settle within 15000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
			if Retired
				DirDelete(Root, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				Debt := {Handle: Handle, Root: Root}
			Critical(PreviousCritical)
		}
	}
	try {
		if Retired {
			_TestPrint("# error-startup terminal calls=" . State.Calls . " code=" . State.Code
				. " capture_delivered=" . (State.Calls == 1) . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# error-startup combined_native_capture " . Line)
			} else
				_TestPrint("# error-startup combined_native_capture UNKNOWN")
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls, "The component must settle once: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The completion diagnostic must be empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The error dialog violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS error-dialog-startup " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _EDOT_Mode in ["current", "close-resolve", "reopen-resolve", "close-reject", "reopen-reject"]
	Test("Error dialog startup: " . _EDOT_Mode . " retains its current owner (error-dialog-startup-owner)", _EDOT_Case.Bind(_EDOT_Mode))
