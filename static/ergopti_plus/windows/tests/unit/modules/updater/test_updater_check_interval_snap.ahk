; static/ergopti_plus/windows/tests/unit/modules/updater/test_updater_check_interval_snap.ahk

; ==============================================================================
; MODULE: Updater Check-Interval Snap Tests
; DESCRIPTION:
; config.toml [updater] check_interval_seconds is read through the shared
; presets: a saved value that is no longer a preset (a retired 10 minutes,
; 2 hours or 2 days, or a hand-edited number) snaps to the nearest preset by
; ratio, so the frequency picker always ticks the cadence actually in force.
; The Windows driver used to keep any number as-is against its own hand-copied
; preset list, and the picker then showed "?".
; ==============================================================================

_UCIS_LoadSnapsSavedIntervalsToPresets() {
	global _IniCache, UPDATER_CHECK_INTERVAL, UPDATER_DEFAULT_INTERVAL
	HadCache := IsSet(_IniCache)
	if HadCache
		SavedCache := _IniCache
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		Cases := [[600, 300], [7200, 3600], [10800, 21600], [172800, 259200],
			[86400, 86400], [60, 300], [0, 0], [31536000, 2592000]]
		for _, Pair in Cases {
			_IniCache := Map("updater", Map("check_interval_seconds", Pair[1]))
			Updater_LoadCheckInterval()
			AssertEqual(Pair[2], UPDATER_CHECK_INTERVAL,
				"a saved " . Pair[1] . " s must load as the preset " . Pair[2] . " s")
			AssertTrue(UpdateSchedule_PresetCode(UPDATER_CHECK_INTERVAL) != "",
				"the loaded interval is always a preset")
		}
		_IniCache := Map()
		Updater_LoadCheckInterval()
		AssertEqual(UpdateSchedule_Timing()["default_check_interval_sec"], UPDATER_CHECK_INTERVAL,
			"an absent key loads the shared default")
		AssertEqual(UpdateSchedule_Timing()["default_check_interval_sec"], UPDATER_DEFAULT_INTERVAL,
			"the driver default is the shared one")
	} finally {
		if HadCache
			_IniCache := SavedCache
		else
			_IniCache := unset
		UPDATER_CHECK_INTERVAL := SavedInterval
	}
}
Test("Updater: a saved check interval snaps to the nearest shared preset", _UCIS_LoadSnapsSavedIntervalsToPresets)

_UCIBOOT_ReadActualInterval(Mode) {
	global ConfigurationFile, _ConfigBootReadFailed, _IniCache, UPDATER_CHECK_INTERVAL, UPDATER_DEFAULT_INTERVAL
	SavedPath := ConfigurationFile, SavedFailed := _ConfigBootReadFailed
	HadCache := IsSet(_IniCache)
	if HadCache
		SavedCache := _IniCache
	SavedInterval := UPDATER_CHECK_INTERVAL
	Root := A_Temp . "\ergopti_updater_interval_admission_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\config.toml", Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created, "the interval fixture must own the directory before any write")
		Raw := Mode == "boolean-false" ? "false" : Mode == "quoted-zero" ? '"0"'
			: Mode == "fraction-half" ? "0.5" : Mode == "zero-control" ? "0" : "3600"
		Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[updater]`ncheck_interval_seconds = " . Raw . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		ConfigurationFile := Path
		Boot := ConfigMigrateBoot(Path)
		AssertEqual("current", Boot["status"])
		_IniCache := ParseConfigTomlFile(Path)
		Snapshot := ConfigTomlBootSnapshot(_IniCache)
		AssertTrue(IsObject(Snapshot), "the interval reader receives the actual bootstrap cache")
		Authored := Snapshot.Document["updater"]["check_interval_seconds"]
		if Mode == "boolean-false"
			AssertTrue(Authored is TOML_Bool && !Authored.Value, "the actual source owner retains a Boolean, never numeric zero")
		else if Mode == "quoted-zero"
			AssertTrue(Authored is String && Authored == "0", "the actual source owner retains a String, never numeric zero")
		else if Mode == "fraction-half"
			AssertTrue(Authored is Float && Authored == 0.5, "the actual source owner retains a non-integral number")
		else
			AssertTrue(Authored is Integer)
		Expected := Mode == "zero-control" ? 0 : Mode == "number-control" ? 3600 : UPDATER_DEFAULT_INTERVAL
		AssertTrue(UPDATER_DEFAULT_INTERVAL > 0, "the default must schedule checks so malformed zero has an observable effect")
		Updater_LoadCheckInterval()
		AssertEqual(Expected, UPDATER_CHECK_INTERVAL, "a non-number source must not silently disable the real updater check cadence")
		AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally {
		ConfigurationFile := SavedPath, _ConfigBootReadFailed := SavedFailed
		if HadCache
			_IniCache := SavedCache
		else
			_IniCache := unset
		UPDATER_CHECK_INTERVAL := SavedInterval
		if Created {
			try _TOML_InvalidateParseCache(Path)
			finally DirDelete(Root, true)
		}
	}
}
for _UCIBOOT_Mode in ["boolean-false", "quoted-zero", "fraction-half", "zero-control", "number-control"]
	Test("Updater actual boot interval admission: " . _UCIBOOT_Mode, _UCIBOOT_ReadActualInterval.Bind(_UCIBOOT_Mode))
