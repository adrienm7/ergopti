; tests/unit/ui/webview/test_hcw_native_reset_owner.ahk

; ==============================================================================
; MODULE: Native Hotstrings Reset Window Ownership
; DESCRIPTION:
; Real native reset, durable writers and rebuild coalescing run in a private child.
; The existing outer rebuild worker explicitly refuses registry/tray publication.
; No WebView, registry registration, tray rendering or physical input claim.
; ==============================================================================

#Requires AutoHotkey v2.0

_HNRT_Source() {
	global _DriverDir
	Support := _DriverDir . "\tests\support\feature_state_boot_smoke.ahk"
	Source := FSReadStrict(Support)
	Boundary := InStr(Source, "`ntry {`n    if (A_Args.Length", true)
	AssertTrue(Boundary > 0, "The genuine boot support exposes its pre-execution graph")
	Prefix := SubStr(Source, 1, Boundary - 1)
	for Name, Expression in Map("_ConfigDir", 'A_Args[2] . "\config\"',
		"_DriverDir", _HCWT_Quote(_DriverDir), "_SharedDir", 'A_Args[2] . "\shared"') {
		Prefix := RegExReplace(Prefix, "m)^global " . Name . " :=[^`n]+", "global " . Name . " := " . Expression, &Count)
		AssertEqual(1, Count, "Only the private boot path declaration changes: " . Name)
	}
	SplitPath(Support, , &SupportDir)
	Code := 'EnvSet("LOCALAPPDATA", A_Args[2] . "\local-app-data")' . "`n"
	for Line in StrSplit(Prefix, "`n") {
		if RegExMatch(Line, "^#Include\s+(.+)$", &Include)
			Line := "#Include " . _MBPT_AbsoluteFile(SupportDir . "\" . Include[1])
		Code .= Line . "`n"
	}
	for Relative in ["_generated\terminators.ahk", "_generated\window_titles.ahk",
		"infra\hotstrings\hotstrings_config.ahk", "ui\hotstrings_config_window\init.ahk",
		"infra\hotstrings\personal_file_controls.ahk", "platform\remap\tap_hold_writer.ahk", "vendor\WebView2.ahk"] {
		Path := _DriverDir . "\" . Relative
		AssertTrue(FileExist(Path), "The component includes its actual complete production owner")
		Code .= "#Include " . Path . "`n"
	}
	Code .= "#Include " . _HCWT_LocaleOwner() . "`n"
	Owners := Map()
	for Symbol in ["_HCWWeb_TryOpen", "HotstringsLanguagePacks", "ReadTomlFile", "Gui_Create",
		"WMPresentWindow", "RebuildHotstringsLive", "_HSE_SourcePriority"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "" && !Owners.Has(Owner), "Each real component owner is uniquely admitted: " . Symbol)
		Owners[Owner] := true
		Code .= "#Include " . Owner . "`n"
	}
	return Code . "#Include " . _DriverDir . "\tests\fixtures\hcw_native_reset_owner_body.ahk`n"
}

; The root is exclusive. Existing targets can only be the donor's authenticated
; copies; equality is checked rather than adopting an incumbent source image.
_HNRT_CopyTree(Source, Target) {
	Count := 0
	Loop Files, Source . "\*", "FD" {
		From := A_LoopFileFullPath, To := Target . "\" . A_LoopFileName
		if InStr(A_LoopFileAttrib, "D") {
			FSCreateDirectoryExclusiveStrict(To)
			Count += _HNRT_CopyTree(From, To)
		} else {
			if !RegExMatch(A_LoopFileName, "i)\.toml$")
				continue
			Before := FSReadBytesStrict(From), Expected := CryptoSha256Bytes(Before)
			AssertTrue(Expected != "")
			if !FileExist(To)
				FileCopy(From, To, false)
			After := FSReadBytesStrict(To)
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Expected, CryptoSha256Bytes(After), "The complete delivered hotstrings pack stays byte-exact")
			Count += 1
		}
	}
	return Count
}

_HNRT_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A prior owned child must retire before a new case")
	Directory := A_Temp . "\ergopti_hcw_reset_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}, Handle := 0, Primary := 0, Retired := false, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		_MBPT_StageAssets(Directory)
		; The actual scope-owner class loads these shared picker tables at import.
		FSCreateDirectoryExclusiveStrict(Directory . "\shared\tap_hold")
		TapSource := _SharedDir . "\tap_hold\defaults.toml", TapTarget := Directory . "\shared\tap_hold\defaults.toml"
		TapBefore := FSReadBytesStrict(TapSource), TapHash := CryptoSha256Bytes(TapBefore)
		FileCopy(TapSource, TapTarget, false)
		TapAfter := FSReadBytesStrict(TapTarget)
		AssertTrue(TapHash != "" && TapBefore.Size == TapAfter.Size)
		AssertEqual(TapHash, CryptoSha256Bytes(TapAfter), "Real include-time tap-hold data stays byte-exact")
		for Relative in ["config", "vendor", "vendor\64bit", "personal", "extensions"]
			FSCreateDirectoryExclusiveStrict(Directory . "\" . Relative)
		Assets := _HNRT_CopyTree(_SharedDir . "\modules\hotstrings", Directory . "\shared\modules\hotstrings")
		AssertTrue(Assets > 5, "The complete actual hotstrings data pack must be staged")
		Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _HNRT_Source()))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _HCWT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native reset child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if AtDeadline.Calls == 0
			Primary := Error("The native reset child did not settle within 15000 ms; deadline_calls=0")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired && IsObject(AtDeadline) && AtDeadline.Calls == 1 && AtDeadline.Code == 0
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	_TestPrint("# hcw-native-reset terminal calls=" . State.Calls . " code=" . State.Code
		. " retired=" . Retired . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
		. " capture=" . JsonStringLiteral(State.Output) . " completion_error=" . JsonStringLiteral(State.ErrorText))
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child tree must acknowledge retirement")
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText)
	AssertExitCode(0, AtDeadline.Code, AtDeadline.Output, "Native reset window ownership")
	AssertContains(AtDeadline.Output, "PASS hcw-native-reset-owner " . Mode)
}

Test("Native hotstrings reset: current window retires after real writes (hcw-native-reset-owner)", _HNRT_Case.Bind("current"))
Test("Native hotstrings reset: old completion preserves reopened window (hcw-native-reset-owner)", _HNRT_Case.Bind("reopen"))
