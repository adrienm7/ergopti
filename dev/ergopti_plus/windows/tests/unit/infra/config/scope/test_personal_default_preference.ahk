; tests/unit/infra/config/scope/test_personal_default_preference.ahk

; ==============================================================================
; MODULE: Personal Default Preference Consumer Roundtrip
; DESCRIPTION:
; Real current-schema writes and native menu callbacks must agree with the
; editor's canonical preference reader. All files and menus are privately owned.
; No GUI/Edge opening, physical menu click, fake writer or migration is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_PDPO_LoggerRun(Callback) {
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_APPEND_OWNERS, _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, _LOGGER_TEST_SINK, _LOGGER_PATH_DATE
	global _LOGGER_REPEAT_ENABLED, _LOGGER_REPEAT_STREAKS, _LOGGER_REPEAT_DATE, _LOGGER_REPEAT_OLDEST
	global _LOGGER_REPEAT_SEQ, _LOGGER_REPEAT_USE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _HealthCheckWarnCount, _HealthCheckErrCount, _HealthCheckLastError, _ED_Enabled
	PreparationCritical := Critical("On")
	try {
		AssertFalse(_LOGGER_FLUSH_ACTIVE, "a foreign native logger flush cannot be borrowed")
		AssertEqual(0, _LOGGER_APPEND_OWNERS.Count + _LOGGER_APPEND_DEBTS.Count + _LOGGER_APPEND_DEBT_REPAIRS.Count,
			"foreign append ownership and debt must remain untouched")
		Saved := _TLOG_CaptureLoggerState()
		Extra := {Sink: _LOGGER_TEST_SINK, PathDate: _LOGGER_PATH_DATE,
			RepeatEnabled: _LOGGER_REPEAT_ENABLED, Streaks: _LOGGER_REPEAT_STREAKS,
			RepeatDate: _LOGGER_REPEAT_DATE, Oldest: _LOGGER_REPEAT_OLDEST,
			Sequence: _LOGGER_REPEAT_SEQ, Use: _LOGGER_REPEAT_USE,
			Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN}
		Warn := IsSet(_HealthCheckWarnCount) ? _HealthCheckWarnCount : unset
		Errors := IsSet(_HealthCheckErrCount) ? _HealthCheckErrCount : unset
		LastError := IsSet(_HealthCheckLastError) ? _HealthCheckLastError : unset
		Enabled := IsSet(_ED_Enabled) ? _ED_Enabled : unset
		Logs := []
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_PATH_DATE := "", _LOGGER_REPEAT_ENABLED := false, _LOGGER_REPEAT_STREAKS := Map()
		_LOGGER_REPEAT_DATE := "", _LOGGER_REPEAT_OLDEST := "", _LOGGER_REPEAT_SEQ := 0, _LOGGER_REPEAT_USE := 0
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		_ED_Enabled := false
		LoggerSetTestSink((Line) => Logs.Push(Line))
	} finally Critical(PreparationCritical)
	try Callback.Call(Logs)
	finally {
		RestoreCritical := Critical("On")
		try {
			_LOGGER_TEST_SINK := Extra.Sink, _LOGGER_PATH_DATE := Extra.PathDate
			_LOGGER_REPEAT_ENABLED := Extra.RepeatEnabled, _LOGGER_REPEAT_STREAKS := Extra.Streaks
			_LOGGER_REPEAT_DATE := Extra.RepeatDate, _LOGGER_REPEAT_OLDEST := Extra.Oldest
			_LOGGER_REPEAT_SEQ := Extra.Sequence, _LOGGER_REPEAT_USE := Extra.Use
			_LOGGER_CLOCK_FN := Extra.Clock, _LOGGER_STAMP_FN := Extra.Stamp
			_HealthCheckWarnCount := IsSet(Warn) ? Warn : unset
			_HealthCheckErrCount := IsSet(Errors) ? Errors : unset
			_HealthCheckLastError := IsSet(LastError) ? LastError : unset
			_ED_Enabled := IsSet(Enabled) ? Enabled : unset
			_TLOG_RestoreLoggerState(Saved)
		} finally Critical(RestoreCritical)
	}
}

_PDPO_Run(Mode) {
	_PDPO_LoggerRun(_PDPO_Case.Bind(Mode))
}

; Find the finished native default child by its actual choices, not the expected
; default caption: that caption is itself one of the inverse business oracles.
_PDPO_DefaultChild(Parent, Labels) {
	Found := 0
	loop TrayMenuItemCount(Parent) {
		Position := A_Index - 1
		Handle := TrayMenuSubmenuHandle(Parent.Handle, Position)
		if !Handle
			continue
		Child := MenuFromHandle(Handle)
		if !(Child is Menu)
			continue
		Alpha := -1, Beta := -1
		loop TrayMenuItemCount(Child) {
			Label := TrayMenuHandleItemCaption(Handle, A_Index - 1)
			if Label == Labels["alpha"]
				Alpha := A_Index - 1
			if Label == Labels["beta"]
				Beta := A_Index - 1
		}
		if Alpha >= 0 && Beta >= 0 {
			AssertFalse(IsObject(Found), "exactly one finished native child owns both default choices")
			Found := {Menu: Child, Handle: Handle, ParentPosition: Position, Alpha: Alpha, Beta: Beta}
		}
	}
	AssertTrue(IsObject(Found), "the actual source must finish its private native default child")
	return Found
}

_PDPO_NativeState(Parent, Child) {
	Alpha := TrayMenuHandleItemState(Child.Handle, Child.Alpha)
	Beta := TrayMenuHandleItemState(Child.Handle, Child.Beta)
	AssertTrue(Alpha != 0xFFFFFFFF && Beta != 0xFFFFFFFF, "native flag queries must acknowledge both exact rows")
	return {Alpha: (Alpha & 0x8) != 0, Beta: (Beta & 0x8) != 0,
		Caption: TrayMenuHandleItemCaption(Parent.Handle, Child.ParentPosition)}
}

_PDPO_Receipt(Mode, Result, Called, Canonical, Legacy, Native, ConfigHash, PersonalHash, Logs) {
	Line := 'RECEIPT personal-default-preference {"mode":' . JsonStringLiteral(Mode)
		. ',"operation_return_type":' . JsonStringLiteral(Type(Result))
		. ',"operation_return":' . JsonStringLiteral(String(Result)) . ',"menu_callback_called":' . Called
		. ',"canonical":' . JsonStringLiteral(String(Canonical)) . ',"legacy":' . JsonStringLiteral(String(Legacy))
		. ',"alpha_checked":' . (Native.Alpha ? 1 : 0) . ',"beta_checked":' . (Native.Beta ? 1 : 0)
		. ',"caption":' . JsonStringLiteral(Native.Caption) . ',"config_raw_sha256":' . JsonStringLiteral(ConfigHash)
		. ',"personal_raw_sha256":' . JsonStringLiteral(PersonalHash) . ',"logs":['
	for Index, Entry in Logs
		Line .= (Index == 1 ? "" : ",") . JsonStringLiteral(Entry)
	_TestPrint("# " . Line . "]}")
}

_PDPO_Case(Mode, Logs) {
	global ScriptInformation, Features, CategoryEnabled, ConfigurationFile
	global _ReadPersonalTomlCache, _PersonalTomlReadGeneration, _PersonalExtTree, _FmtCountCache, _PrevDefaultLabel
	global _TomlUnreadableFiles, _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles, _ED_Busy, _ED_PendingRecord
	AssertTrue(Mode == "current" || Mode == "menu-to-editor" || Mode == "editor-to-menu")
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
	Directory := A_Temp . "\ergopti-personal-default-" . A_ScriptHwnd . "-" . A_TickCount . "-" . Random(10000, 999999)
	OwnedDirectory := false, OwnedMenus := [], Primary := 0, Cleanup := 0, Path := ""
	OldCritical := Critical("Off"), OldSuspend := A_IsSuspended
	Suspend(false)
	try {
		FSCreateDirectoryExclusiveStrict(Directory)
		OwnedDirectory := true
		Path := Directory . "\config.toml", PersonalPath := Directory . "\personal.toml"
		Keep := "é" . Chr(0x1F600), KeepLine := 'keep = "' . Keep . '"'
		LegacyInitial := Mode == "current" ? "beta" : "alpha"
		Source := _CMJFixtureCurrentSource(Chr(0xFEFF) . '[personal_editor]`ndefault_section = "alpha"`n'
			. 'DefaultSection = "' . LegacyInitial . '"`nclose_on_add = "1"`n[private]`n' . KeepLine . "`n")
		Personal := '[_meta]`nsections_order = ["alpha", "beta"]`n[_meta.sections]`nalpha = "Alpha '
			. Keep . '"`nbeta = "Beta ' . Keep . '"`n[[alpha]]`n[[beta]]`n'
		AssertEqual(1, FSWriteCreateDurable(Path, Source), "private config is created without replacing a foreign file")
		AssertEqual(1, FSWriteCreateDurable(PersonalPath, Personal), "private personal source is created exclusively")
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"], "genuine current-schema boot must admit the private source")
		AssertEqual(0, Boot["read_only"])
		AssertTrue(FSUtf8ExactMatches(Path, Source), "boot preserves the authored source instead of forging readiness")
		ConfigurationFile := Path
		ScriptInformation := ScriptInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		_ReadPersonalTomlCache := false, _TomlUnreadableFiles := Map()
		_PersonalExtTree := Map(), _FmtCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		for Name in ["alpha", "beta"]
			_ConfigSeedPersonalHotstring(Features, Name)
		CategoryEnabled := Map("Hotstrings", false)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		AssertEqual("alpha", _EditorPrefGet("default_section", ""), "the real editor consumer admits the initial canonical value")
		AssertEqual(LegacyInitial, _EditorPrefGet("DefaultSection", ""), "the unknown legacy value remains a distinct original key")
		PersonalHash := CryptoSha256Bytes(FileRead(PersonalPath, "RAW"))
		AssertTrue(RegExMatch(PersonalHash, "^[a-fA-F0-9]{64}$") > 0, "actual CNG must hash the complete private source")
		Result := "not-called", Called := 0, Native := {Alpha: false, Beta: false, Caption: "not-rendered"}
		if Mode != "menu-to-editor" {
			Result := _EditorPrefSet("default_section", "beta")
			AssertTrue(Result, "the genuine canonical writer must affirm actual persistence before consumer comparison")
			AssertEqual("beta", _EditorPrefGet("default_section", ""), "actual durable writer/readback is the affirmative prerequisite")
		}
		if Mode != "current" {
			Rows := _HS_PersonalRows()
			if Rows is Array {
				for Row in Rows
					if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
						OwnedMenus.Push(Row["submenu"])
			}
			AssertTrue(Rows is Array && Rows.Length == 1 && OwnedMenus.Length == 1,
				"real declared personal source must hand off one finished native root")
			Parent := OwnedMenus[1], Model := ReadPersonalToml(), Labels := _HS_BuildDisambiguatedSectionLabels(Model)
			Child := _PDPO_DefaultChild(Parent, Labels)
			if Mode == "menu-to-editor" {
				Initial := _PDPO_NativeState(Parent, Child)
				AssertTrue(Initial.Alpha && !Initial.Beta, "the genuine current native menu starts on alpha")
				Id := TrayMenuHandleItemId(Child.Handle, Child.Beta)
				AssertTrue(Id != 0xFFFFFFFF && _MenuDispatchCallbacks.Has(Id)
					&& HasMethod(_MenuDispatchCallbacks[Id], "Call"), "the real native beta row owns its registered callback")
				Callback := _MenuDispatchCallbacks[Id]
				Called += 1
				Result := Callback.Call()
			}
			Native := _PDPO_NativeState(Parent, Child)
		}
		Canonical := _EditorPrefGet("default_section", ""), Legacy := _EditorPrefGet("DefaultSection", "")
		Raw := FSReadUtf8Exact(Path), ConfigHash := CryptoSha256Bytes(FileRead(Path, "RAW"))
		AssertTrue(RegExMatch(ConfigHash, "^[a-fA-F0-9]{64}$") > 0)
		AssertFalse(IsObject(_ConfigWriteLeaseCurrent(Path)), "real completion releases its config owner before business")
		AssertContains(Raw, KeepLine, "unrelated exact Unicode source survives the real update")
		AssertTrue(FSUtf8ExactMatches(PersonalPath, Personal), "personal content is never rewritten by a preference choice")
		AssertEqual(PersonalHash, CryptoSha256Bytes(FileRead(PersonalPath, "RAW")), "all private personal bytes remain exact")
		_PDPO_Receipt(Mode, Result, Called, Canonical, Legacy, Native, ConfigHash, PersonalHash, Logs)
		if Mode == "editor-to-menu" {
			AssertTrue(Native.Beta && !Native.Alpha, "canonical editor choice must be the native menu's selected default (personal-default-preference-owner)")
			AssertEqual(t("menu.hotstrings.default_category_prefix") . Labels["beta"], Native.Caption,
				"native default caption must describe the same canonical choice")
		} else
			AssertEqual("beta", Canonical, "the real menu and editor must share one canonical default preference (personal-default-preference-owner)")
		AssertEqual(LegacyInitial, Legacy, "unknown legacy preference is preserved without broadening or migrating its ownership")
	} catch Any as Failure {
		Primary := Failure
	} finally {
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

Test("personal default preference: canonical writer preserves conflicting legacy and Unicode data (personal-default-preference-owner)",
	_PDPO_Run.Bind("current"))
Test("personal default preference: native menu choice reaches the canonical editor reader (personal-default-preference-owner)",
	_PDPO_Run.Bind("menu-to-editor"))
Test("personal default preference: canonical editor choice is reconstructed by the native menu (personal-default-preference-owner)",
	_PDPO_Run.Bind("editor-to-menu"))
