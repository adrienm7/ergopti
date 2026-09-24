; static/ergopti_plus/windows/tests/unit/test_updater_check_interval_snap.ahk

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
