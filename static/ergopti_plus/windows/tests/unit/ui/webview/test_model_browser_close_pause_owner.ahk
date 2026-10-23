; tests/unit/ui/webview/test_model_browser_close_pause_owner.ahk

; ==============================================================================
; MODULE: Model Browser Native Close Pause Tests
; DESCRIPTION:
; Runs the genuine SDK selection, native deferred apply and actual native Gui
; destruction in a private child with boot-admitted configuration and the full
; central collector/writer. Browser COM and tray repaint are explicit boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

_MBPT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_MBPT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; Generated data is intentionally outside the authored-source resolver. Find
; its one complete function owner in the canonical generated export directory.
_MBPT_GeneratedOwner(Symbol) {
	global _DriverDir
	Owners := Map()
	Loop Files, _DriverDir . "\_generated\*.ahk", "F" {
		Owner := A_LoopFileFullPath
		Text := FSReadStrict(Owner), OwnerCode := _DriverMaskNonCode(&Text)
		Count := _DriverTopLevelDefinitionCount(&OwnerCode, Symbol)
		if Count {
			AssertEqual(1, Count, "The real generated owner must declare its requested data function once")
			Owners[Owner] := true
		}
	}
	AssertEqual(1, Owners.Count, "The canonical generated exports must contain one data owner for " . Symbol)
	for Owner in Owners
		return Owner
}

; Resolve the actual include identity before redirecting its private copy. The
; authored-source resolver deliberately rejects lexical tests/../ paths.
_MBPT_AbsoluteFile(Path) {
	BufferPath := Buffer(65536, 0)
	Length := DllCall("kernel32\GetFullPathNameW", "Str", Path, "UInt", 32768,
		"Ptr", BufferPath.Ptr, "Ptr", 0, "UInt")
	AssertTrue(Length > 0 && Length < 32768 && FileExist(Path) != "",
		"The diagnostic dependency must have an actual canonical file")
	return StrGet(BufferPath)
}

; Keep the real writer and its caught exception. Only a private whole owner
; gains one diagnostic call; inverse reconstruction authenticates every edit.
_MBPT_WriterDiagnosticOwner(Directory) {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("_ConfigInvokeCommitWriter", _DriverDir)
	AssertTrue(Owner != "", "The actual configuration writer owner must exist")
	Original := FSReadStrict(Owner), Masked := _DriverMaskNonCode(&Original)
	AssertEqual(1, _DriverTopLevelDefinitionCount(&Masked, "_ConfigInvokeCommitWriter"))
	Definition := _DriverFindFunctionDefinition(&Original, "_ConfigInvokeCommitWriter")
	AssertTrue(IsObject(Definition), "The real writer definition must be locatable in RAW source")
	Depth := 1, Cursor := Definition.OpenPos + 1
	while Cursor <= StrLen(Masked) && Depth {
		Character := SubStr(Masked, Cursor, 1)
		if Character == "{"
			Depth += 1
		else if Character == "}"
			Depth -= 1
		Cursor += 1
	}
	AssertEqual(0, Depth, "The actual RAW writer body must close exactly")
	RawFunction := SubStr(Original, Definition.Idx, Cursor - Definition.Idx)
	RegExReplace(RawFunction, "m)^`t} catch as Err \{", "", &Catches)
	AssertEqual(1, Catches, "The actual writer must retain its one original caught exception")
	Anchor := "} catch as Err {`n`t`tFailureDetail .="
	Insertion := "} catch as Err {`n`t`t_MBWD_Caught(Err, Stage)`n`t`tFailureDetail .="
	ChangedFunction := StrReplace(RawFunction, Anchor, Insertion, true, &Insertions)
	AssertEqual(1, Insertions, "Only the actual writer catch may gain diagnostic observation")
	Changed := SubStr(Original, 1, Definition.Idx - 1) . ChangedFunction . SubStr(Original, Cursor)
	SplitPath(Owner, , &OwnerDir)
	Rewrites := [], Private := ""
	for Index, Line in StrSplit(Changed, "`n") {
		OriginalLine := Line
		if RegExMatch(Line, "^#Include\s+(.+)$", &Include) {
			AssertTrue(FileExist(OwnerDir . "\" . Include[1]) != "",
				"Each private owner include must retain its genuine original sibling")
			Line := "#Include " . _MBPT_AbsoluteFile(OwnerDir . "\" . Include[1])
			Rewrites.Push({ Original: OriginalLine, Private: Line })
		}
		Private .= (Index > 1 ? "`n" : "") . Line
	}
	AssertEqual(2, Rewrites.Length, "The real configuration owner has exactly two sibling imports")
	Inverse := Private
	for Rewrite in Rewrites {
		Inverse := StrReplace(Inverse, Rewrite.Private, Rewrite.Original, true, &Count)
		AssertEqual(1, Count, "Each private include must reverse to its original directive once")
	}
	Inverse := StrReplace(Inverse, Insertion, Anchor, true, &Undone)
	AssertEqual(1, Undone)
	AssertEqual(0, StrCompare(Original, Inverse, true), "The diagnostic insertion must be exactly reversible")
	RawHash := CryptoSha256Bytes(FSReadBytesStrict(Owner))
	AssertTrue(RawHash != "")
	AssertEqual(RawHash, CryptoSha256(Chr(0xFEFF) . Inverse), "Inverse reconstruction must preserve the complete RAW owner")
	Target := Directory . "\writer_diagnostic_config_io.ahk"
	AssertTrue(FSWriteCreateDurable(Target, Chr(0xFEFF) . Private) != 0)
	PrivateHash := CryptoSha256Bytes(FSReadBytesStrict(Target))
	AssertTrue(PrivateHash != "")
	Helper := _DriverDir . "\tests\fixtures\model_browser_writer_exception_diagnostics.ahk"
	HelperHash := CryptoSha256Bytes(FSReadBytesStrict(Helper))
	AssertTrue(HelperHash != "")
	_TestPrint("# model-browser-writer-diagnostic source_owner=" . Owner . " original_raw_sha256=" . RawHash
		. " private_raw_sha256=" . PrivateHash . " helper_raw_sha256=" . HelperHash
		. " raw_function_sha256=" . CryptoSha256(RawFunction)
		. " insertions=" . Insertions . " include_rewrites=" . Rewrites.Length)
	return { Original: _MBPT_AbsoluteFile(Owner), Private: Target, Helper: Helper }
}

_MBPT_ChildSource(Directory) {
	global _DriverDir, _SharedDir
	Diagnostic := _MBPT_WriterDiagnosticOwner(Directory)
	Support := _DriverDir . "\tests\support\feature_state_boot_smoke.ahk"
	Source := FSReadStrict(Support)
	Boundary := InStr(Source, "`ntry {`n    if (A_Args.Length", true)
	AssertTrue(Boundary > 0, "The genuine boot support must expose its pre-execution graph")
	Prefix := SubStr(Source, 1, Boundary - 1)
	for Name, Expression in Map("_ConfigDir", 'A_Args[2] . "\config\"',
		"_DriverDir", _MBPT_Quote(_DriverDir), "_SharedDir", 'A_Args[2] . "\shared"') {
		Prefix := RegExReplace(Prefix, "m)^global " . Name . " :=[^`n]+", "global " . Name . " := " . Expression, &Count)
		AssertEqual(1, Count, "Only this private boot declaration may change: " . Name)
	}
	SplitPath(Support, , &SupportDir)
	; The real registry reader must never consult another process's parse cache.
	Code := 'EnvSet("LOCALAPPDATA", A_Args[2] . "\local-app-data")' . "`n"
	Code .= "#Include " . Diagnostic.Helper . "`n"
	Routes := 0
	for Line in StrSplit(Prefix, "`n") {
		if RegExMatch(Line, "^#Include\s+(.+)$", &Include) {
			Path := _MBPT_AbsoluteFile(SupportDir . "\" . Include[1])
			if StrCompare(Path, Diagnostic.Original, false) == 0 {
				Path := Diagnostic.Private
				Routes += 1
			}
			Line := "#Include " . Path
		}
		Code .= Line . "`n"
	}
	AssertEqual(1, Routes, "Only the genuine support prefix may redirect the actual writer owner")
	_TestPrint("# model-browser-writer-diagnostic subject_routes=" . Routes . " kind=PrivateChildCatchInstrumentation")
	for GeneratedSymbol in ["LocaleTableData", "UpdateChannelRegistryData", "UpdateScheduleData"]
		Code .= "#Include " . _MBPT_GeneratedOwner(GeneratedSymbol) . "`n"
	Owners := Map()
	for Symbol in ["HotPath_Now", "t", "I18nGetLocale", "LLM_GetModelIndex", "LLM_Defaults_Load",
		"LLM_DisplayIndentValues", "LLM_Option_TryNormalize", "_TrayRootErrorIsSilent",
		"LLM_Menu_ApplySharedDefaults", "LLM_Engine_Init", "HotstringsLanguageCategories", "ReadTomlFile", "MagicEditorPhysicalCatalogue", "NotifierSend", "MasterGateDesiredFeatures",
		"MetricsFiltersApplyManifestDefaults", "MS_SaveBuiltToIni", "WPMWidget_Show",
		"AppPicker_SelectionsEqual", "UpdateChannels_Ids", "UpdateSchedule_Timing",
		"Updater_LoadChannel", "LLM_ModelBrowser_Show"] {
		Root := Symbol == "LLM_DisplayIndentValues" ? _DriverDir . "\..\_shared" : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, Root)
		AssertTrue(Owner != "", "The model-selection child requires its whole genuine owner: " . Symbol)
		AssertFalse(Owners.Has(Owner), "Each explicit component owner must be distinct")
		Owners[Owner] := true
		Code .= "#Include " . Owner . "`n"
		if Symbol == "LLM_Defaults_Load"
			Code .= "LLM_Defaults_Load()`n"
	}
	AssertEqual(23, Owners.Count, "All native, data, configuration, menu and runtime owners must be included")
	Fixture := _DriverDir . "\tests\fixtures\model_browser_close_pause_owner_body.ahk"
	AssertTrue(FileExist(Fixture))
	return Code . "#Include " . Fixture . "`n"
}

; Keep even error-reporting locale-cache writes inside this exact private root.
; These are byte-verified copies of the shipped data, never synthetic defaults.
_MBPT_StageAssets(Directory) {
	global _SharedDir
	for Relative in ["shared", "shared\modules", "shared\modules\llm", "shared\modules\hotstrings", "shared\modules\menu",
		"shared\modules\diagnostics", "shared\data", "shared\data\locales", "shared\data\keycodes", "shared\core",
		"shared\core\config_schema", "shared\core\config_schema\examples", "local-app-data"]
		FSCreateDirectoryExclusiveStrict(Directory . "\" . Relative)
	; Stage the complete shipped schema pack for the genuine boot owner, plus
	; canonical presentation/privacy policies for diagnostics. The component
	; does not claim every reserved policy is read on its successful cold path.
	for Relative in ["modules\llm\defaults.json", "modules\llm\models.json", "modules\hotstrings\_index.toml", "data\locales\fr.json", "data\locales\en.json",
		"modules\menu\menu_manifest.json", "modules\diagnostics\redaction.json", "data\keycodes\physical_keys.json",
		"core\config_schema\migrations.toml", "core\config_schema\config.schema.json",
		"core\config_schema\tap_hold.schema.json", "core\config_schema\SCHEMA.md",
		"core\config_schema\examples\hs_tap_hold.example.toml", "core\config_schema\examples\personal_info.example.toml",
		"core\config_schema\examples\hs_config.example.toml", "core\config_schema\examples\ahk_config.example.toml",
		"core\config_schema\examples\hotstrings_config.example.toml", "core\config_schema\examples\ahk_tap_hold.example.toml"] {
		Source := _SharedDir . "\" . Relative, Target := Directory . "\shared\" . Relative
		Before := FSReadBytesStrict(Source), Expected := CryptoSha256Bytes(Before)
		AssertTrue(Expected != "" && !FileExist(Target), "Only an exclusive private target may receive authentic data")
		FileCopy(Source, Target, false)
		After := FSReadBytesStrict(Target)
		AssertEqual(Before.Size, After.Size, "The private asset must preserve the complete source byte count")
		AssertEqual(Expected, CryptoSha256Bytes(After), "The private asset must preserve the complete source RAW image")
	}
}

_MBPT_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier model browser child must retire first")
	Directory := A_Temp . "\ergopti_model_browser_close_pause_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		_MBPT_StageAssets(Directory)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _MBPT_ChildSource(Directory)) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _MBPT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public model browser child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact model browser child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# model-browser-close-pause-owner terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-close-pause-owner combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# model-browser-close-pause-owner completion_error " . Line)
			} else
				_TestPrint("# model-browser-close-pause-owner combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact model browser child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real model browser violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS model-browser-close-pause-owner " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _MBPT_Mode in ["current", "during-close", "paused-entry"]
	Test("Model browser selection: " . _MBPT_Mode . " preserves native pause ownership (model-browser-close-pause-owner)",
		_MBPT_Case.Bind(_MBPT_Mode))
