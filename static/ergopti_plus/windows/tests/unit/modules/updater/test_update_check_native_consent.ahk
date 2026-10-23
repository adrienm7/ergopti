; tests/unit/modules/updater/test_update_check_native_consent.ahk

; ==============================================================================
; MODULE: Native Update Check Consent Tests
; DESCRIPTION:
; A private child drives real native buttons and the existing deferred action
; timer. The genuine logger sink publishes a new public result at the callout;
; activation is a passive terminal download port and never installs anything.
; ==============================================================================

#Requires AutoHotkey v2.0

_UCNO_GeneratedOwner(Symbol) {
	global _DriverDir
	Owners := []
	loop files _DriverDir . "\_generated\*.ahk", "F" {
		Text := FileRead(A_LoopFileFullPath, "UTF-8")
		if RegExMatch(Text, "m)^" . Symbol . "\(")
			Owners.Push(A_LoopFileFullPath)
	}
	AssertEqual(1, Owners.Length, "A required generated function must have one genuine owner: " . Symbol)
	return Owners[1]
}

_UCNO_ChildSource() {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["LoggerInfo", "WallClockTimestamp", "TickElapsed", "UpdateCheck_Begin", "UpdateChannels_Field", "WMPresentWindow"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "The consent child needs the unique whole owner of " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Symbol in ["WindowTitle", "UpdateChannelRegistryData"]
		Source .= "#Include " . _UCNO_GeneratedOwner(Symbol) . "`n"
	for Symbol in ["Gui_Create", "Gui_HarmoniseButtonWidths", "_Updater_NewRequestContext", "_Updater_ChannelLabel",
		"_Updater_NormalizeTag", "_Updater_ParseVersion", "_Updater_ComparePreId", "_Updater_ComparePre", "_Updater_CompareVersions"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every genuine reached function must be nonempty: " . Symbol)
		Source .= Body . "`n"
	}
	Owner := _DriverProductionFileForSymbol("_Updater_RetireManagedDownloadFailure", _DriverDir)
	AssertTrue(Owner != "", "The real terminal-failure registry owner must resolve")
	AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class ManagedNetworkTerminalFailure \{.*?^\}", &StateClass) > 0,
		"The consent child must load the real terminal-failure registry class")
	Source .= StateClass[0] . "`n"
	for Spec in [["Gui_HarmoniseButtonWidths", ["UI_BTN_MIN_W"]],
		["_Updater_NewRequestContext", ["UPDATER_CHANNEL", "UPDATER_REQUEST_ORIGIN_BACKGROUND", "UPDATER_REQUEST_ORIGIN_MANUAL",
			"_UpdaterPauseGeneration", "_UpdaterBackgroundGeneration", "_UpdaterChannelEpoch", "_UpdaterRequestCounter"]]] {
		Owner := _DriverProductionFileForSymbol(Spec[1], _DriverDir)
		AssertTrue(Owner != "", "Every native request policy declaration needs its genuine owner")
		Text := FileRead(Owner, "UTF-8")
		for Name in Spec[2] {
			AssertTrue(RegExMatch(Text, "m)^global " . Name . "[ \t]*:=[^`n]+", &Declaration) > 0,
				"The native consent policy declaration must be genuine: " . Name)
			Source .= Declaration[0] . "`n"
		}
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\update_check_native_consent_body.ahk`n"
}

_UCNO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_UCNO_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_update_consent_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _UCNO_ChildSource()) != 0)
		_TestPrint("# update-check-native-consent-source script=" . CryptoSha256Bytes(FSReadBytesStrict(Script))
			. " runtime=" . CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
			. " fixture=" . CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\update_check_native_consent_body.ahk")))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _UCNO_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact update-check-native-consent child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
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
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# update-check-native-consent-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS update-check-native-consent " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Update consent: native current and closed actions keep their owner (update-check-native-consent)", _UCNO_Case.Bind("current-close"))
Test("Update consent: old native action cannot install its successor (update-check-native-consent)", _UCNO_Case.Bind("replaced"))
Test("Update consent: fresh successor native button remains usable (update-check-native-consent)", _UCNO_Case.Bind("successor-current"))
