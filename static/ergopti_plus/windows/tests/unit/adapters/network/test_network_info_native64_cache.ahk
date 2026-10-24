; tests/unit/adapters/network/test_network_info_native64_cache.ahk

; ==============================================================================
; MODULE: WLAN Native64 Cache Contract Tests
; DESCRIPTION: Real public accessors query the whole adapter through logical WLAN
; call boundaries backed by genuine Buffers. Only two native clock tokens and six
; WLAN call sites are projected. No live WLAN, credentials or physical long pause.
; ==============================================================================

#Requires AutoHotkey v2.0

_NWCT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_NWCT_Overlay(Source) {
	Original := Source, Code := _DriverMaskNonCode(&Source), Changes := []
	for Name in ["_NI_QueryWlan", "_NI_CacheWlanResult"] {
		AssertEqual(1, _DriverTopLevelDefinitionCount(&Code, Name), "The actual adapter definition must be unique: " . Name)
		Body := _DriverExtractFunctionBody(&Source, Name), BodyCode := _DriverMaskNonCode(&Body)
		AssertTrue(RegExMatch(BodyCode, "\bA_TickCount\b", &Clock) > 0,
			"Each actual cache boundary must read its native clock: " . Name)
		AssertFalse(RegExMatch(BodyCode, "\bA_TickCount\b", , Clock.Pos[0] + Clock.Len[0]) > 0)
	}
	Position := 1
	while RegExMatch(Code, "\bA_TickCount\b", &Clock, Position) {
		Changes.Push({Position: Clock.Pos[0], Length: Clock.Len[0], Text: "_NWCF_Now()"})
		Position := Clock.Pos[0] + Clock.Len[0]
	}
	AssertEqual(2, Changes.Length, "Only the publisher and cache predicate clocks may be projected")
	Calls := Map("WlanOpenHandle", "_NWCF_Open", "WlanEnumInterfaces", "_NWCF_Enum",
		"WlanQueryInterface", "_NWCF_Query", "WlanFreeMemory", "_NWCF_Free", "WlanCloseHandle", "_NWCF_Close")
	Counts := Map(), Position := 1
	Pattern := 'DllCall\("Wlanapi\\([A-Za-z_][A-Za-z0-9_]*)"'
	while RegExMatch(Source, Pattern, &Call, Position) {
		if SubStr(Code, Call.Pos[0], 7) == "DllCall" {
			Name := Call[1]
			AssertTrue(Calls.Has(Name), "Every WLAN call must use an explicitly typed logical boundary")
			Counts[Name] := Counts.Get(Name, 0) + 1
			Changes.Push({Position: Call.Pos[0], Length: 7, Text: Calls[Name]})
		}
		Position := Call.Pos[0] + Call.Len[0]
	}
	AssertEqual(5, Counts.Count)
	for Name, Replacement in Calls
		AssertEqual(Name == "WlanFreeMemory" ? 2 : 1, Counts.Get(Name, 0), "Exact WLAN boundary count: " . Name)
	AssertEqual(8, Changes.Length, "Two clock and six WLAN call sites are the complete overlay")
	; Applying edits from the end preserves genuine source offsets.
	Loop Changes.Length {
		Largest := 1
		for Index, Change in Changes
			if Change.Position > Changes[Largest].Position
				Largest := Index
		Change := Changes.RemoveAt(Largest)
		Source := SubStr(Source, 1, Change.Position - 1) . Change.Text . SubStr(Source, Change.Position + Change.Length)
	}
	Inverse := Source, Count := 0
	Inverse := StrReplace(Inverse, "_NWCF_Now()", "A_TickCount", true, &Count)
	AssertEqual(2, Count)
	for Name, Replacement in Calls {
		Inverse := StrReplace(Inverse, Replacement . "(", "DllCall(", true, &Count)
		AssertEqual(Name == "WlanFreeMemory" ? 2 : 1, Count)
	}
	AssertEqual(Original, Inverse, "The whole adapter must invert exactly, with all cache/public algorithms untouched")
	return Source
}

_NWCT_Program(Directory) {
	global _DriverDir
	NetworkOwner := _DriverProductionFileForSymbol("_NI_QueryWlan", _DriverDir)
	CryptoOwner := _DriverProductionFileForSymbol("CryptoSha256", _DriverDir)
	NetworkSource := _NWCT_Overlay(FSReadStrict(NetworkOwner))
	CryptoSource := FSReadStrict(CryptoOwner)
	Fixture := _DriverDir . "\tests\fixtures\network_info_native64_cache_probe.ahk"
	AssertTrue(FSWriteCreateDurable(Directory . "\network_info.ahk", Chr(0xFEFF) . NetworkSource) != 0)
	AssertTrue(FSWriteCreateDurable(Directory . "\crypto.ahk", Chr(0xFEFF) . CryptoSource) != 0)
	AssertTrue(FSWriteCreateDurable(Directory . "\probe.ahk", Chr(0xFEFF) . FSReadStrict(Fixture)) != 0)
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
		. "#Include " . _NWCT_Quote(Directory . "\network_info.ahk") . "`n"
		. "#Include " . _NWCT_Quote(Directory . "\crypto.ahk") . "`n"
		. "#Include " . _NWCT_Quote(Directory . "\probe.ahk") . "`n"
}

_NWCT_Complete(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_NWCT_Field(Output, Name) {
	Pattern := "m)^NWCF_RESULT " . Name . " ([A-Za-z]+) ([^`r`n]*)`r?$"
	Position := RegExMatch(Output, Pattern, &Match)
	AssertTrue(Position > 0 && !RegExMatch(Output, Pattern, , Position + Match.Len[0]),
		"Exactly one actual public result must be exported: " . Name)
	return {Kind: Match[1], Value: Match[2]}
}

_NWCT_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "A prior child with unknown retirement must remain owned")
	Directory := A_Temp . "\ergopti_wlan_cache64_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false, AtDeadline := 0
	PreviousCritical := Critical("Off")
	try {
		Program := _NWCT_Program(Directory), Script := Directory . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . Program) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode], _NWCT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The actual adapter child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The WLAN cache child did not settle within 15000 ms.")
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
	ExportFailure := 0
	try {
		if State.Calls == 1
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# wlan-native64-child " . Line)
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "Exact child tree retirement must precede the business verdict")
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, "PREREQUISITE: real adapter composition and logical WLAN protocol must complete. " . AtDeadline.Output)
	AssertContains(AtDeadline.Output, "NWCF_COMPLETE " . Mode)
	Signal := _NWCT_Field(AtDeadline.Output, "signal"), Hash := _NWCT_Field(AtDeadline.Output, "hash")
	SnapshotSignal := _NWCT_Field(AtDeadline.Output, "snapshot_signal"), SnapshotHash := _NWCT_Field(AtDeadline.Output, "snapshot_hash")
	Status := _NWCT_Field(AtDeadline.Output, "status"), Queries := _NWCT_Field(AtDeadline.Output, "queries")
	CacheAt := _NWCT_Field(AtDeadline.Output, "cache_at")
	if IsObject(ExportFailure)
		throw ExportFailure
	ExpectedSignal := Mode == "inside-ttl" ? "25" : "85"
	ExpectedHash := Mode == "inside-ttl" ? "f5cbe4c29262cd4cc9f4556e26fa408fc5fa73f990e98fa2fb7f678981586b3c"
		: "e671dc18755bd03a33e720542a6efa6c673d36fc341e329dccb63e26fb545165"
	AssertEqual(ExpectedSignal, Signal.Value, "The actual public signal must honor the full64 WLAN cache TTL (wlan-cache-native64-owner)")
	AssertEqual("Integer", Signal.Kind)
	AssertEqual(ExpectedHash, Hash.Value)
	AssertEqual("connected", Status.Value)
	AssertEqual(ExpectedSignal, SnapshotSignal.Value)
	AssertEqual(ExpectedHash, SnapshotHash.Value)
	AssertEqual(Mode == "inside-ttl" ? "1" : "2", Queries.Value, "All three public fields must share one query per fresh result")
	ExpectedAt := Mode == "inside-ttl" ? "4294968296" : Mode == "exact-ttl" ? "4294970296" : "30064773296"
	AssertEqual("Integer", CacheAt.Kind)
	AssertEqual(ExpectedAt, CacheAt.Value, "Only a genuine refresh may move the full-width cache origin")
}

Test("WLAN cache: calls within 1999ms reuse one query (wlan-cache-native64-owner)", _NWCT_Case.Bind("inside-ttl"))
Test("WLAN cache: the exact 2000ms boundary refreshes public fields (wlan-cache-native64-owner)", _NWCT_Case.Bind("exact-ttl"))
Test("WLAN cache: an old result beyond six DWORD eras is refreshed (wlan-cache-native64-owner)", _NWCT_Case.Bind("long-gap"))
