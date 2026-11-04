; tests/unit/infra/config/scope/test_personal_close_on_add.ahk

; ==============================================================================
; MODULE: Personal Close-on-Add Consumer Agreement
; DESCRIPTION:
; Real current-schema config, native personal menu and WebView initData producer
; agree on absent and explicit preferences. No GUI/Edge or physical click claim.
; Existing logger isolation and private-owner cleanup come from the prior sibling.
; ==============================================================================

#Requires AutoHotkey v2.0

_PCAP_AutoClose(Js) {
	Position := RegExMatch(Js, ",auto_close:(true|false)(?=,)", &Value)
	AssertTrue(Position > 0, "the actual initData producer must expose its Boolean auto_close field")
	AssertEqual(0, RegExMatch(Js, ",auto_close:", , Position + StrLen(Value[0])), "the emitted field must be unique")
	return Value[1] == "true"
}

_PCAP_NativeState(Parent) {
	Label := t("menu.hotstrings.close_on_add"), Found := 0
	loop TrayMenuItemCount(Parent) {
		Position := A_Index - 1
		if TrayMenuHandleItemCaption(Parent.Handle, Position) != Label
			continue
		AssertFalse(IsObject(Found), "the actual close-on-add row must be unique")
		Flags := TrayMenuHandleItemState(Parent.Handle, Position)
		Id := TrayMenuHandleItemId(Parent.Handle, Position)
		AssertTrue(Flags != 0xFFFFFFFF && Id != 0xFFFFFFFF && Id > 0, "native flags and registration ID must be acknowledged")
		Found := {Id: Id, Checked: (Flags & 0x8) != 0}
	}
	AssertTrue(IsObject(Found), "the finished native menu must contain the actual close-on-add row")
	return Found
}

_PCAP_Run(Mode) {
	_PDPO_LoggerRun(_PCAP_Case.Bind(Mode))
}

_PCAP_Case(Mode, Logs) {
	global ScriptInformation, Features, CategoryEnabled, ConfigurationFile
	global _ReadPersonalTomlCache, _PersonalTomlReadGeneration, _PersonalExtTree, _FmtCountCache, _PrevDefaultLabel
	global _TomlUnreadableFiles, _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles, _ED_Busy, _ED_PendingRecord
	global _HsEdWeb_Gui, _HsEdWeb_OpeningSource
	AssertFalse(IsSet(_HsEdWeb_Gui) && _HsEdWeb_Gui is Gui, "a foreign WebView host cannot be borrowed for payload observation")
	SavedWebSource := IsSet(_HsEdWeb_OpeningSource) ? _HsEdWeb_OpeningSource : unset
	AssertTrue(Mode == "absent" || Mode == "off" || Mode == "on")
	AssertFalse(_ED_Busy || IsObject(_ED_PendingRecord), "a foreign error-dialog request must not be folded into this private case")
	SavedInfo := ScriptInformation, SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	SavedCache := _ReadPersonalTomlCache, SavedGeneration := _PersonalTomlReadGeneration, SavedUnreadable := _TomlUnreadableFiles
	SavedTree := IsSet(_PersonalExtTree) ? _PersonalExtTree : unset
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedDefault := IsSet(_PrevDefaultLabel) ? _PrevDefaultLabel : unset
	State := MasterGateState(), SavedState := State.Clone()
	Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
		_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
	for Table in Tables
		Before.Push(Table.Clone())
	Directory := A_Temp . "\ergopti-personal-close-" . A_ScriptHwnd . "-" . A_TickCount . "-" . Random(10000, 999999)
	OwnedDirectory := false, OwnedMenus := [], Primary := 0, Cleanup := 0, Path := ""
	OldCritical := Critical("Off"), OldSuspend := A_IsSuspended
	Suspend(false)
	try {
		FSCreateDirectoryExclusiveStrict(Directory)
		OwnedDirectory := true
		Path := Directory . "\config.toml", PersonalPath := Directory . "\personal.toml"
		Keep := "é" . Chr(0x1F600), KeepLine := 'keep = "' . Keep . '"'
		Source := _CMJFixtureCurrentSource(Chr(0xFEFF) . '[personal_editor]`ndefault_section = "alpha"`n[private]`n' . KeepLine . "`n")
		Personal := '[_meta]`nsections_order = ["alpha"]`n[_meta.sections]`nalpha = "Alpha '
			. Keep . '"`n[[alpha]]`n'
		AssertEqual(1, FSWriteCreateDurable(Path, Source), "private current config is created exclusively")
		AssertEqual(1, FSWriteCreateDurable(PersonalPath, Personal), "private personal file is created exclusively")
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"], "real current-schema boot admits this private source")
		AssertEqual(0, Boot["read_only"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "boot cannot silently insert the missing editor preference")
		ConfigurationFile := Path
		ScriptInformation := ScriptInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		_ReadPersonalTomlCache := false, _TomlUnreadableFiles := Map()
		_PersonalExtTree := Map(), _FmtCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		_ConfigSeedPersonalHotstring(Features, "alpha")
		CategoryEnabled := Map("Hotstrings", false)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		ExpectedInitial := Mode == "on"
		if Mode == "absent"
			AssertEqual("_absent_", _EditorPrefGet("close_on_add", "_absent_"), "the real decoder confirms the absent-key premise")
		else {
			AssertTrue(_EditorPrefSet("close_on_add", ExpectedInitial ? "1" : "0"), "affirmative real ConfigCommit establishes each explicit control")
			AssertEqual(ExpectedInitial ? "1" : "0", _EditorPrefGet("close_on_add", "_absent_"), "real persisted readback precedes consumer observations")
		}
		PersonalHash := CryptoSha256Bytes(FileRead(PersonalPath, "RAW"))
		ConfigBeforeHash := CryptoSha256Bytes(FileRead(Path, "RAW"))
		AssertTrue(RegExMatch(PersonalHash, "^[a-fA-F0-9]{64}$") > 0)
		Rows := _HS_PersonalRows()
		if Rows is Array {
			for Row in Rows
				if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
					OwnedMenus.Push(Row["submenu"])
		}
		AssertTrue(Rows is Array && Rows.Length == 1 && OwnedMenus.Length == 1,
			"the real personal source publishes one privately owned native root")
		Parent := OwnedMenus[1]
		Initial := _PCAP_NativeState(Parent)
		InitialJs := _HsEdWeb_InitDataJs()
		InitialPayload := _PCAP_AutoClose(InitialJs)
		AssertTrue(_MenuDispatchCallbacks.Has(Initial.Id) && HasMethod(_MenuDispatchCallbacks[Initial.Id], "Call"),
			"the finished native check row owns its actual registered callback")
		Callback := _MenuDispatchCallbacks[Initial.Id]
		Result := Callback.Call()
		Callback := 0
		After := _PCAP_NativeState(Parent)
		AfterJs := _HsEdWeb_InitDataJs()
		AfterPayload := _PCAP_AutoClose(AfterJs)
		Canonical := _EditorPrefGet("close_on_add", "_absent_")
		Raw := FSReadUtf8Exact(Path), ConfigHash := CryptoSha256Bytes(FileRead(Path, "RAW"))
		AssertFalse(IsObject(_ConfigWriteLeaseCurrent(Path)), "real writer completion releases its exact config owner")
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path), "consumer comparison cannot borrow recovery debt")
		AssertContains(Raw, KeepLine, "unrelated Unicode bytes survive the real preference update")
		AssertTrue(FSUtf8ExactMatches(PersonalPath, Personal), "a preference callback never rewrites personal content")
		AssertEqual(PersonalHash, CryptoSha256Bytes(FileRead(PersonalPath, "RAW")))
		_TestPrint('# RECEIPT personal-close-on-add {"mode":' . JsonStringLiteral(Mode)
			. ',"callback_calls":1,"operation_type":' . JsonStringLiteral(Type(Result))
			. ',"operation_return":' . JsonStringLiteral(String(Result))
			. ',"initial_checked":' . (Initial.Checked ? 1 : 0) . ',"initial_auto_close":' . (InitialPayload ? 1 : 0)
			. ',"after_checked":' . (After.Checked ? 1 : 0) . ',"after_auto_close":' . (AfterPayload ? 1 : 0)
			. ',"canonical":' . JsonStringLiteral(String(Canonical))
			. ',"config_before_sha256":' . JsonStringLiteral(ConfigBeforeHash)
			. ',"config_after_sha256":' . JsonStringLiteral(ConfigHash) . ',"personal_sha256":' . JsonStringLiteral(PersonalHash)
			. ',"initial_payload":' . JsonStringLiteral(InitialJs) . ',"after_payload":' . JsonStringLiteral(AfterJs) . '}')
		AssertEqual(ExpectedInitial, Initial.Checked, "native menu must use the editor's false default and explicit preference (personal-close-on-add-owner)")
		AssertEqual(ExpectedInitial, InitialPayload, "the actual initData producer must affirm each initial editor value")
		AssertEqual(ExpectedInitial ? "0" : "1", Canonical, "one actual menu callback durably toggles the same initial preference")
		AssertEqual(!ExpectedInitial, After.Checked, "the retained native row reflects the actual committed toggle")
		AssertEqual(!ExpectedInitial, AfterPayload, "the real editor payload reads back the menu's durable update")

	} catch Any as Failure {
		Primary := Failure
	} finally {
		Callback := 0
		try _HS_PersonalReleaseMenus(OwnedMenus)
		catch Any as Failure
			Cleanup := Failure
		try {
			CurrentTables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
				_MenuDispatchClickSequences, _MenuDispatchOwnerHandles]
			for Index, Table in Tables {
				AssertTrue(CurrentTables[Index] == Table, "global dispatcher containers retain their exact foreign identities")
				AssertEqual(Before[Index].Count, Table.Count, "native retirement must leave no callback/handle registration behind")
				for Key, Value in Before[Index]
					AssertTrue(Table.Has(Key) && Table[Key] == Value, "foreign callback/owner identities remain exact")
			}
		} catch Any as Failure {
			if !IsObject(Cleanup)
				Cleanup := Failure
		}
		if OwnedDirectory && Path != "" {
			try {
				AssertFalse(IsObject(_ConfigWriteLeaseCurrent(Path)), "an unsettled real writer retains its private source")
				AssertFalse(_ConfigPublicationHasRecoveryDebt(Path), "durable recovery debt must retain its private files")
			} catch Any as Failure {
				if !IsObject(Cleanup)
					Cleanup := Failure
			}
		}
		_HsEdWeb_OpeningSource := IsSet(SavedWebSource) ? SavedWebSource : unset
		ScriptInformation := SavedInfo, Features := SavedFeatures, CategoryEnabled := SavedCategories
		ConfigurationFile := IsSet(SavedConfig) ? SavedConfig : unset
		_ReadPersonalTomlCache := SavedCache, _PersonalTomlReadGeneration := SavedGeneration, _TomlUnreadableFiles := SavedUnreadable
		_PersonalExtTree := IsSet(SavedTree) ? SavedTree : unset
		_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
		_PrevDefaultLabel := IsSet(SavedDefault) ? SavedDefault : unset
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		if OwnedDirectory && !IsObject(Cleanup) {
			try DirDelete(Directory, true)
			catch Any as Failure
				Cleanup := Failure
		}
		Suspend(OldSuspend)
		Critical(OldCritical)
	}
	if IsObject(Primary) {
		if IsObject(Cleanup)
			Primary.Message .= " [private cleanup refused: " . Cleanup.Message . "]"
		throw Primary
	}
	if IsObject(Cleanup)
		throw Cleanup
}

Test("personal close-on-add: absent preference agrees across native menu and editor payload (personal-close-on-add-owner)", _PCAP_Run.Bind("absent"))
Test("personal close-on-add: explicit off persists one native toggle to the editor payload (personal-close-on-add-owner)", _PCAP_Run.Bind("off"))
Test("personal close-on-add: explicit on persists one native toggle to the editor payload (personal-close-on-add-owner)", _PCAP_Run.Bind("on"))
