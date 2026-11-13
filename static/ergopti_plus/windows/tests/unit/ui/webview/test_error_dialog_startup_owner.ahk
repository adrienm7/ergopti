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
	; Masking every generated file for each symbol of each child cost seconds per
	; case, and no test rewrites a generated file during a run.
	static Owners := Map()
	if Owners.Has(Symbol)
		return Owners[Symbol]
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
	Owners[Symbol] := Found
	return Found
}

_EDOT_Source(Root, LogOpeners := false) {
	global _DriverDir, _SharedDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "OnError(_EDOS_BootError)`n" . '_EDOS_Phase("autoexecute-entry")' . "`n"
		. "global _EDOS_Root := " . _EDOT_Quote(Root) . "`n"
		. "global _SharedDir := " . _EDOT_Quote(Root . "\shared") . "`n"
		. "global _VendorDir := " . _EDOT_Quote(Root . "\vendor") . "`n"
		. "global _ConfigDir := " . _EDOT_Quote(Root . "\config\") . "`n"
		. "global _LogsDir := " . _EDOT_Quote(Root . "\logs\") . "`n"
		. "global ConfigurationFile := " . _EDOT_Quote(Root . "\config\absent.toml") . "`n"
		. 'global _AhkSubDir := "autohotkey\", _ALTGR_KANA_FIXUP := false' . "`n"
	; The logger observes the real constructor journal even before admission.
	; Whole configuration owners keep this isolated graph faithful and inert.
	for Vendor in ["Promise.ahk", "ComVar.ahk", "WebView2.ahk"] {
		Source .= "#Include " . _DriverDir . "\vendor\" . Vendor . "`n"
		Source .= "_EDOS_Phase(" . _EDOT_Quote("included vendor " . Vendor) . ")`n"
	}
	for Symbol in ["AppDirsFolderName", "WindowTitle", "LoggerSubFilesData", "UpdateChannelRegistryData", "UpdateScheduleData"] {
		Source .= "#Include " . _EDOT_Generated(Symbol) . "`n"
		Source .= "_EDOS_Phase(" . _EDOT_Quote("included generated " . Symbol) . ")`n"
	}
	KeyOwner := _DriverDir . "\_generated\config_keys.ahk"
	AssertTrue(FileExist(KeyOwner), "The logger requires its canonical generated configuration key classes.")
	Source .= "#Include " . KeyOwner . "`n"
	Source .= '_EDOS_Phase("included generated configuration keys")' . "`n"
	Owners := Map()
	for Symbol in ["JsonStringLiteral", "CryptoSha256Bytes", "FSReadBytesStrict", "HTTPIsValidUtf8", "WallClockTimestamp", "TickElapsed64",
		"_LoggerPrivacyConfig", "ErrorPolicy_Decide", "ManifestFindEntryByPath", "ConfigBindingIdentityTapPublication", "TapKeyBindingId",
		"IsCategoryGated", "_CategoryEnabledKey", "ConfigMigrateBoot", "ConfigTransitionInspect",
		"ConfigTransitionProductionPort", "PerfCount", "IniCacheGet", "Gui_Create", "t", "UpdateChannels_Ids", "UpdateSchedule_Timing", "Updater_CurrentVersion",
		"CrashReport_Dir", "DiagSnapshot_ResolveCommit", "KS_IsDown", "HealthCheck_Config", "_HealthCheck_Paths",
		"ErrorReport_Compose", "IssueReport_Markdown", "Redact_Apply", "WebView_SharedEnvironment", "ErrorDialog_Init", "DayLog_CheckLimits"] {
		OwnerRoot := Symbol == "ConfigBindingIdentityTapPublication" ? _SharedDir : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, OwnerRoot)
		AssertTrue(Owner != "", "The error child requires its genuine whole owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Source .= "#Include " . Owner . "`n"
			Source .= "_EDOS_Phase(" . _EDOT_Quote("included owner " . Symbol) . ")`n"
		}
	}
	Source .= "#Include " . _DriverDir . "\infra\bundle.ahk`n"
	Source .= '_EDOS_Phase("included bundle; before fixture body")' . "`n"
	if LogOpeners {
		Owner := _DriverProductionFileForSymbol("LogOpeners_OpenTodayErrors", _DriverDir)
		AssertTrue(Owner != "", "The log reader child must use the real UI action owner")
		Source .= "#Include " . Owner . "`n"
	}
	return Chr(0xFEFF) . Source . "#Include " . _DriverDir . "\tests\fixtures\"
		. (LogOpeners ? "log_openers_buffered_owner_body.ahk" : "error_dialog_startup_owner_body.ahk") . "`n"
}

; Exclusive native creation needs each parent before its children. The folders
; come from the staged files themselves, so they follow wherever the data lives.
_EDOT_CreateParents(Base, Relatives) {
	Made := Map()
	for Relative in Relatives {
		Parts := StrSplit(Relative, "\"), Folder := Base
		Loop Parts.Length - 1 {
			Folder .= "\" . Parts[A_Index]
			if !Made.Has(Folder) {
				FSCreateDirectoryExclusiveStrict(Folder)
				Made[Folder] := true
			}
		}
	}
}

_EDOT_Assets(Root) {
	global _SharedDir
	; Exclusive native creation requires each parent before its children.
	for Subdir in ["config", "logs", "vendor", "vendor\64bit", "shared"]
		FSCreateDirectoryExclusiveStrict(Root . "\" . Subdir)
	Inputs := ["diagnostics\data\schema.json", "diagnostics\data\redaction.json", "diagnostics\data\issue_templates.json",
		"diagnostics\data\error_policy.json", "diagnostics\data\recent_issues.json", "diagnostics\data\day_log.json",
		"updater\data\defaults.json", "core\i18n\data\locales\en.json", "core\i18n\data\locales\fr.json"]
	_EDOT_CreateParents(Root . "\shared", Inputs)
	for Relative in Inputs {
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

_EDOT_Case(Mode, LogOpeners := false) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "A previous unretired child prevents another component")
	Root := A_Temp . "\ergopti_error_startup_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_EDOT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _EDOT_Source(Root, LogOpeners)))
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
	AssertContains(AtDeadline.Output, (LogOpeners ? "PASS log-openers-buffered " : "PASS error-dialog-startup ") . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _EDOT_Mode in ["current", "close-resolve", "reopen-resolve", "close-reject", "reopen-reject",
	"current-refusal", "reopen-resolve-refusal"]
	Test("Error dialog startup: " . _EDOT_Mode . " retains its current owner (error-dialog-startup-owner)", _EDOT_Case.Bind(_EDOT_Mode))

for _LOB_Mode in ["errors", "main", "errors-denied", "main-denied", "errors-busy", "main-busy",
	"daylog", "daylog-denied", "daylog-busy"]
	Test("Log openers: " . _LOB_Mode . " reads the settled native buffered sink (log-openers-buffered-owner)",
		_EDOT_Case.Bind(_LOB_Mode, true))
