; tests/unit/modules/keystats/test_switch_destination_privacy_owner.ahk

; ==============================================================================
; MODULE: Captured Switch Destination Privacy Tests
; DESCRIPTION:
; Genuine focus refresh and context projection retain the captured destination
; while a native timer admits another public focus. Full central appends, rather
; than recording stubs, decide which switch payloads reach the shared queue.
; ==============================================================================

#Requires AutoHotkey v2.0

_KSD_ChildSource(Network := false) {
	global _DriverDir
	Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	for Symbol in ["_KL_ContextProject", "MF_ShouldFilter", "HotPath_Now", "WICaptureBoundedFocusSnapshot", "WallClockTimestamp", "TickElapsed64", "_TextCodepointWidth"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(Owner != "", "Every actual whole owner must resolve: " . Symbol)
		Source .= "#Include " . Owner . "`n"
	}
	for Definition in ["Keystats", "KLHook", "KLHookConst"] {
		Symbol := Definition == "Keystats" ? "KL_AppendLog" : "KL_Hook_RefreshContext"
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		AssertTrue(RegExMatch(FileRead(Owner, "UTF-8"), "ms)^class " . Definition . " \{.*?^\}", &StateClass) > 0,
			"The child must use the actual state class " . Definition)
		Source .= StateClass[0] . "`n"
	}
	for Symbol in ["KL_Hook_RefreshContext", "KL_Hook_AdvanceContextWatermarks", "KL_LogAppSwitch",
		"KL_LogWindowSwitch", "KL_AppendLog", "KL_AssignStableEventId", "KL_AllocEventId",
		"KL_RecordPrivacyHit", "KL_NowTimestamp"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "Every reached production function needs its real body: " . Symbol)
		if Symbol == "KL_LogAppSwitch" || Symbol == "KL_LogWindowSwitch"
			Body := RegExReplace(Body, "^" . Symbol, "_KSD_Native" . SubStr(Symbol, 4))
		Source .= Body . "`n"
	}
	Flush := _DriverFuncBody("KL_FlushBuffer")
	AssertTrue(RegExMatch(Flush, "^KL_FlushBuffer\(") > 0)
	Source .= RegExReplace(Flush, "^KL_FlushBuffer", "_KSD_NativeFlush") . "`n"
	; KL_AppendLog and the hook sources ask the capture gate (Suspend or the
	; metrics pause) that the collection module owns.
	GateOwner := _DriverProductionFileForSymbol("KL_CaptureHeld", _DriverDir)
	AssertTrue(RegExMatch(FileRead(GateOwner, "UTF-8"), "ms)^class KLCollection \{.*?^\}", &GateClass) > 0,
		"The child must use the actual capture gate class KLCollection")
	Source .= GateClass[0] . "`n" . _DriverFuncBody("KL_CaptureHeld") . "`n"
	if Network {
		for Symbol in ["CryptoSha256", "NI_GetWifiSnapshot"] {
			Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
			AssertTrue(Owner != "")
			Source .= "#Include " . Owner . "`n"
		}
		Owner := _DriverProductionFileForSymbol("KL_Net_WifiTick", _DriverDir)
		NetworkSource := FileRead(Owner, "UTF-8")
		for Definition in ["KLNetConst", "KLNet"] {
			AssertTrue(RegExMatch(NetworkSource, "ms)^class " . Definition . " \{.*?^\}", &StateClass) > 0)
			Source .= StateClass[0] . "`n"
		}
		for Symbol in ["KL_Net_ReduceWifiSample", "KL_Net_WifiTick"] {
			Body := _DriverFuncBody(Symbol)
			AssertTrue(Body != "")
			Source .= Body . "`n"
		}
		Source .= "#Include " . _DriverDir . "\tests\fixtures\wifi_dashboard_kpi_owner_body.ahk`n"
		Source .= "global _KSD_ExtraExercise := _KSD_WifiReportExercise`n"
	} else Source .= "global _KSD_ExtraExercise := 0`n"
	return Source . "#Include " . _DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk`n"
}

_KSD_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_KSD_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_switch_destination_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KSD_ChildSource(InStr(Mode, "wifi-report-") == 1)) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
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
					_TestPrint("# switch-destination-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS switch-destination-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

for _KSD_Mode in ["app-third", "title-third", "app-live", "title-live", "outgoing-private", "outgoing-title-private", "public"]
	Test("Keystats switch destinations: " . _KSD_Mode . " respects captured privacy (switch-destination-privacy-owner)",
		_KSD_Case.Bind(_KSD_Mode))


for _KSD_CaptionMode in ["caption-app-distinct", "caption-app-same"]
	Test("Keystats window caption ownership: " . _KSD_CaptionMode . " closes each application interval (window-caption-app-owner)",
		_KSD_Case.Bind(_KSD_CaptionMode))


_KSD_WifiReportKpi(ChangedNetwork) {
	global KLRLastReplayFailure
	Output := _KSD_Case(ChangedNetwork ? "wifi-report-switch" : "wifi-report-signal")
	SavedDevice := Keystats.device_id, SavedLiteral := Keystats._device_id_lit
	SavedFailure := KLRLastReplayFailure
	Db := _WJFM_OpenMemory()
	try {
		Keystats.device_id := "wifi-report-device"
		Keystats._device_id_lit := SQLite_Q(Keystats.device_id)
		AssertTrue(KLR_LoadSchema(Db))
		Count := 0, Day := ""
		for Line in StrSplit(Output, "`n", "`r") {
			if InStr(Line, "WIFIROW ") != 1
				continue
			Fields := StrSplit(SubStr(Line, 9), "|")
			AssertEqual(7, Fields.Length)
			Entry := Map("type", "network_change", "_event_id", Integer(Fields[1]),
				"timestamp", Fields[2], "app", Fields[3], "ssid_hash", Fields[4],
				"signal", Fields[6], "connection_state", Fields[7])
			if Fields[5] != ""
				Entry["prev_ssid_hash"] := Fields[5]
			Day := SubStr(Fields[2], 1, 10)
			for Sql in KL_BuildInserts(Entry)
				AssertTrue(SQLite_Exec(Db, Sql), "The actual event builder must persist every admitted native-child row")
			Count += 1
		}
		AssertEqual(ChangedNetwork ? 3 : 2, Count, "Baseline and signal transitions remain real persisted network observations")
		AssertEqual(Count, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_network;")[1]["n"])
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true) >= 0)
		Manifest := KLR_ReadManifestBase(Db)
		Wifi := 0
		for _, Apps in Manifest
			if Apps.Has("_system")
				Wifi += Apps["_system"].Get("wifi_changes", 0)
		_TestPrint("# wifi-dashboard-kpi network_switch=" . ChangedNetwork . " raw_network_rows=" . Count . " wifi_changes=" . Wifi)
		AssertEqual(ChangedNetwork ? 1 : 0, Wifi,
			"The actual dashboard KPI counts a known SSID change, excluding baseline, signal-only changes and unknown adapter samples")
	} finally {
		SQLite_Close(Db)
		Keystats.device_id := SavedDevice, Keystats._device_id_lit := SavedLiteral
		KLRLastReplayFailure := SavedFailure
	}
}
for _KSD_WifiChanged in [false, true]
	Test("Keystats Wi-Fi dashboard: " . (_KSD_WifiChanged ? "known network change" : "signal-only control") . " reaches the actual manifest (wifi-dashboard-kpi-owner)",
		_KSD_WifiReportKpi.Bind(_KSD_WifiChanged))

Test("Keystats window caption ownership: case-only title change closes its exact interval (window-caption-case-owner)",
	_KSD_Case.Bind("caption-case-only"))


_KSD_WifiConnectivityKpi(Scoped) {
	global KLRLastReplayFailure
	Output := _KSD_Case("wifi-report-connectivity-flow")
	SavedDevice := Keystats.device_id, SavedLiteral := Keystats._device_id_lit
	SavedFailure := KLRLastReplayFailure
	Db := _WJFM_OpenMemory()
	try {
		Keystats.device_id := "wifi-connectivity-device"
		Keystats._device_id_lit := SQLite_Q(Keystats.device_id)
		AssertTrue(KLR_LoadSchema(Db))
		Count := 0, Dates := [], SeenDates := Map()
		for Line in StrSplit(Output, "`n", "`r") {
			if InStr(Line, "WIFIFLOW ") != 1
				continue
			Fields := StrSplit(SubStr(Line, 10), "|")
			AssertEqual(8, Fields.Length)
			Entry := Map("type", "network_change", "_event_id", Integer(Fields[1]),
				"timestamp", Fields[2], "app", Fields[3], "ssid_hash", Fields[4],
				"signal", Fields[6], "connection_state", Fields[7], "prev_connection_state", Fields[8])
			if Fields[5] != ""
				Entry["prev_ssid_hash"] := Fields[5]
			Day := SubStr(Fields[2], 1, 10)
			if !SeenDates.Has(Day) {
				SeenDates[Day] := true
				Dates.Push(Day)
			}
			for Sql in KL_BuildInserts(Entry)
				AssertTrue(SQLite_Exec(Db, Sql), "Canonical producer metadata must reach native SQLite unchanged")
			Count += 1
		}
		AssertEqual(5, Count)
		AssertTrue(KLR_PrepareTypingProjection(Db))
		Scope := Scoped ? Dates : 0
		Loop 2 {
			AssertTrue(KLR_RebuildAggregates(Db, Scope))
			AssertTrue(KLR_RebuildWalkerAggregates(Db, true, Scope) >= 0)
			Wifi := 0
			for _, Apps in KLR_ReadManifestBase(Db)
				if Apps.Has("_system")
					Wifi += Apps["_system"].Get("wifi_changes", 0)
			_TestPrint("# wifi-connectivity-kpi scoped=" . Scoped . " pass=" . A_Index . " raw_rows=" . Count . " wifi_changes=" . Wifi)
			AssertEqual(3, Wifi, "SSID change, disconnect and reconnect count; baseline, signal and unknown do not")
		}
	} finally {
		SQLite_Close(Db)
		Keystats.device_id := SavedDevice, Keystats._device_id_lit := SavedLiteral
		KLRLastReplayFailure := SavedFailure
	}
}
for _KSD_WifiFlowScoped in [false, true]
	Test("Keystats Wi-Fi connectivity: " . (_KSD_WifiFlowScoped ? "day-scoped" : "full") . " rebuild preserves actual transitions (wifi-connectivity-kpi-owner)",
		_KSD_WifiConnectivityKpi.Bind(_KSD_WifiFlowScoped))
