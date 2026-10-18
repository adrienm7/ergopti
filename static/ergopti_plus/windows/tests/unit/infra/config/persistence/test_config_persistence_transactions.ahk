; tests/unit/infra/config/persistence/test_config_persistence_transactions.ahk

; ==============================================================================
; MODULE: AHK-15 Configuration Persistence Transactions
; DESCRIPTION:
; Behavioural regressions for boolean-returning persistence and the Suspend
; reload hand-off. The fakes fail each member of a related two-update mutation,
; marker publication, claim and consumption independently. They assert that a
; failed durable commit publishes no candidate Map, schedules/reloads/toggles
; nothing, and emits exactly one visible failure signal.
; ==============================================================================

#Requires AutoHotkey v2.0

; The headless runner deliberately omits the UI-only WPM display module, while
; the production SaveFullConfig canonicalization path reads its static state.
; A minimal contract double lets this test execute that real path instead of
; silently skipping it through the runner's otherwise-unset globals. The real
; MetricsFilters class is included centrally because its persistence paths now
; have behavioural global-barrier coverage.
class WPMWidgetConst {
	static CFG_VISIBLE := "wpm_widget_visible"
	static CFG_X := "wpm_widget_x"
	static CFG_Y := "wpm_widget_y"
	static CFG_COLORS := "wpm_widget_colors"
	static CFG_GRAPH := "wpm_widget_graph"
}

class WPMWidget {
	static visible := false
	static pos_x := 0
	static pos_y := 0
	static use_colors := false
	static show_graph := false
	static _gdip_font := 0
	static _gdip_fmt := 0
}

global _CPT_ConfigFailAt := 0
global _CPT_ConfigWriteCalls := 0
global _CPT_ConfigUpdates := []
global _CPT_NotifyCalls := 0
global _CPT_TimerCalls := 0

_CPT_ResetConfigFakes(FailAt := 0) {
	global _CPT_ConfigFailAt, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates
	global _CPT_NotifyCalls, _CPT_TimerCalls
	_CPT_ConfigFailAt := FailAt
	_CPT_ConfigWriteCalls := 0
	_CPT_ConfigUpdates := []
	_CPT_NotifyCalls := 0
	_CPT_TimerCalls := 0
}

_CPT_ConfigWriter(Path, Updates) {
	global _CPT_ConfigFailAt, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates
	_CPT_ConfigWriteCalls += 1
	_CPT_ConfigUpdates := Updates
	for Index, _ in Updates {
		if (_CPT_ConfigFailAt == Index)
			return false
	}
	return true
}

_CPT_Notify(Message, Options) {
	global _CPT_NotifyCalls
	_CPT_NotifyCalls += 1
}

_CPT_ThrowingNotify(Message, Options) {
	global _CPT_NotifyCalls
	_CPT_NotifyCalls += 1
	throw Error("injected notifier failure")
}

_CPT_Timer(Callback, Period) {
	global _CPT_TimerCalls
	_CPT_TimerCalls += 1
}





; ============================================
; ============================================
; ======= 1/ Related-field transaction =======
; ============================================
; ============================================

; A controlled writer still enters through the genuine native source owner.
; Admit an actual fresh destination without creating a file, so the historical
; failure assertions continue to prove that no durable effect occurred.
_CPT_PrepareAbsentConfig(Path) {
	AssertFalse(_ConfigWriteTerminalIsActive(), "the isolated subject never clears an inherited terminal barrier")
	AssertFalse(FSStrictExists(Path), "the fresh subject must be physically absent before Boot")
	Boot := ConfigMigrateBoot(Path)
	AssertEqual("absent", Boot["status"], "the actual fresh Boot supplies the source admission")
	AssertEqual(0, Boot["read_only"])
	AssertTrue(ConfigSchemaCanPrepareWrite(Path))
	AssertEqual("", TOML_WriteRefusal(Path))
	AssertFalse(FSStrictExists(Path), "native source initialization does not publish a fake writer result")
}

_CPT_GestureFailureLeavesBothMapsUntouched(FailAt) {
	global ConfigurationFile, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates, _CPT_NotifyCalls
	OriginalPath := ConfigurationFile
	Path := A_Temp . "\ergopti_ahk15_persistence_" . FailAt . ".toml"
	try FileDelete(Path)
	ConfigurationFile := Path
	Assignments := Map("tap_3", "copy")
	Parameters := Map("gesture__tap_3__open_url", "https://old.example")
	ParameterCandidate := Map(
		"has_value", true,
		"key", "gesture__tap_3__open_url",
		"value", "https://new.example")
	_CPT_ResetConfigFakes(FailAt)
	try {
		_CPT_PrepareAbsentConfig(Path)
		Committed := _GestureCommitAssignment(&Assignments, &Parameters,
			"gestures", "tap_3", "open_url", ParameterCandidate,
			_CPT_ConfigWriter, _CPT_Notify)
		AssertFalse(Committed, "the injected update failure must abort the logical mutation")
		AssertEqual("copy", Assignments["tap_3"], "assignment Map must remain unchanged")
		AssertEqual("https://old.example", Parameters["gesture__tap_3__open_url"],
			"parameter Map must remain unchanged")
		AssertFalse(FileExist(Path), "the failing fake writer must leave disk unchanged")
		AssertEqual(1, _CPT_ConfigWriteCalls, "related fields must use one batch call")
		AssertEqual(2, _CPT_ConfigUpdates.Length, "assignment and parameter must share that batch")
		AssertEqual(1, _CPT_NotifyCalls, "one failed logical mutation must show exactly one error")
	} finally {
		ConfigurationFile := OriginalPath
		try FileDelete(Path)
	}
}

_CPT_GestureFirstUpdateFailure() {
	_CPT_GestureFailureLeavesBothMapsUntouched(1)
}
Test("AHK-15-persistence: first related update failure publishes no Map",
	_CPT_GestureFirstUpdateFailure)

_CPT_GestureSecondUpdateFailure() {
	_CPT_GestureFailureLeavesBothMapsUntouched(2)
}
Test("AHK-15-persistence: second related update failure publishes no Map",
	_CPT_GestureSecondUpdateFailure)

_CPT_GestureSuccessPublishesBothMaps() {
	global ConfigurationFile, _CPT_ConfigWriteCalls, _CPT_NotifyCalls
	OriginalPath := ConfigurationFile
	ConfigurationFile := A_Temp . "\ergopti_ahk15_success.toml"
	Assignments := Map("tap_3", "copy")
	Parameters := Map("gesture__tap_3__open_url", "https://old.example")
	ParameterCandidate := Map(
		"has_value", true,
		"key", "gesture__tap_3__open_url",
		"value", "https://new.example")
	_CPT_ResetConfigFakes()
	try {
		_CPT_PrepareAbsentConfig(ConfigurationFile)
		Committed := _GestureCommitAssignment(&Assignments, &Parameters,
			"gestures", "tap_3", "open_url", ParameterCandidate,
			_CPT_ConfigWriter, _CPT_Notify)
		AssertTrue(Committed)
		AssertEqual("open_url", Assignments["tap_3"])
		AssertEqual("https://new.example", Parameters["gesture__tap_3__open_url"])
		AssertEqual(1, _CPT_ConfigWriteCalls)
		AssertEqual(0, _CPT_NotifyCalls)
	} finally {
		ConfigurationFile := OriginalPath
	}
}
Test("AHK-15-persistence: successful related batch publishes both Maps",
	_CPT_GestureSuccessPublishesBothMaps)

_CPT_GestureUnknownActionNeverReachesPersistence() {
	global _CPT_ConfigWriteCalls, _CPT_ConfigUpdates
	Assignments := Map("tap_3", "copy")
	Parameters := Map()
	_CPT_ResetConfigFakes()
	Committed := _GestureCommitAssignment(&Assignments, &Parameters,
		"gestures", "tap_3", "__audit_unknown_action__",
		Map("has_value", false), _CPT_ConfigWriter, _CPT_Notify)
	AssertFalse(Committed,
		"an action absent from GESTURE_ACTIONS must be rejected before persistence")
	AssertEqual(0, _CPT_ConfigWriteCalls,
		"a rejected action must never enter the configuration writer")
	AssertEqual(0, _CPT_ConfigUpdates.Length,
		"a rejected action must not construct a persistence batch")
	AssertEqual("copy", Assignments["tap_3"],
		"a rejected action must leave the live assignment unchanged")
}
Test("gesture assignment: an unknown action is rejected before persistence (AHK-149)",
	_CPT_GestureUnknownActionNeverReachesPersistence)

_CPT_PersonalPreferenceFailureIsReturnedAndVisible() {
	global ConfigurationFile, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates, _CPT_NotifyCalls
	SavedPath := ConfigurationFile
	Path := A_Temp . "\ergopti_ahk15_editor_pref.toml"
	try FileDelete(Path)
	ConfigurationFile := Path
	_CPT_ResetConfigFakes(1)
	try {
		_CPT_PrepareAbsentConfig(Path)
		AssertFalse(_EditorPrefSet("close_on_add", "1", _CPT_ConfigWriter, _CPT_Notify),
			"the personal-editor preference setter must propagate a false write")
		AssertFalse(FileExist(Path), "a failed preference write must leave disk unchanged")
		AssertEqual(1, _CPT_ConfigWriteCalls, "one preference change must issue one batch")
		AssertEqual(1, _CPT_ConfigUpdates.Length, "the preference batch must contain one field")
		AssertEqual(1, _CPT_NotifyCalls, "the preference failure must be visible exactly once")
	} finally {
		ConfigurationFile := SavedPath
		try FileDelete(Path)
	}
}
Test("AHK-15-persistence: personal-editor preference failure is returned and visible",
	_CPT_PersonalPreferenceFailureIsReturnedAndVisible)

_CPT_FailureNotifierCannotEscapePersistenceBoundary() {
	global ConfigurationFile, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates, _CPT_NotifyCalls
	SavedPath := ConfigurationFile
	Path := A_Temp . "\ergopti_ahk15_notifier.toml"
	try {
		_CPT_PrepareAbsentConfig(Path)
		ConfigurationFile := Path
		_CPT_ResetConfigFakes(1)
		Returned := ConfigCommitUpdates(Path,
			[{ Section: "script", Key: "locale", Value: "fr" }],
			"the injected notifier failure", _CPT_ConfigWriter, _CPT_ThrowingNotify)
		AssertFalse(Returned,
			"a secondary notifier exception must not replace the writer's false status")
		AssertEqual(1, _CPT_ConfigWriteCalls, "the original writer refusal must precede the notifier exception")
		AssertEqual(1, _CPT_NotifyCalls, "the real writer refusal invokes the throwing notifier exactly once")
		AssertEqual(1, _CPT_ConfigUpdates.Length)
		AssertFalse(FileExist(Path), "the controlled failed writer creates no source")
	} finally {
		ConfigurationFile := SavedPath
		try FileDelete(Path)
	}
}
Test("AHK-15-persistence: failure notifier cannot escape the persistence boundary",
	_CPT_FailureNotifierCannotEscapePersistenceBoundary)

_CPT_TargetedWriteCannotBeOverwrittenByStaleCanonicalState() {
	global ConfigurationFile, CategoryEnabled, _DriverReady, _SaveFullConfigReady
	global Features, ScriptInformation, ScriptShortcutAssignments
	global KeyboardShortcutAssignments, GestureAssignments, _LLM_Menu_Loaded
	SavedPath := ConfigurationFile
	SavedCategories := CategoryEnabled
	SavedFeatures := Features
	SavedScriptInformation := ScriptInformation
	HadScriptAssignments := IsSet(ScriptShortcutAssignments)
	if HadScriptAssignments
		SavedScriptAssignments := ScriptShortcutAssignments
	HadKeyboardAssignments := IsSet(KeyboardShortcutAssignments)
	if HadKeyboardAssignments
		SavedKeyboardAssignments := KeyboardShortcutAssignments
	HadGestureAssignments := IsSet(GestureAssignments)
	if HadGestureAssignments
		SavedGestureAssignments := GestureAssignments
	HadLlmMenuLoaded := IsSet(_LLM_Menu_Loaded)
	if HadLlmMenuLoaded
		SavedLlmMenuLoaded := _LLM_Menu_Loaded
	HadDriverReady := IsSet(_DriverReady)
	if HadDriverReady
		SavedDriverReady := _DriverReady
	HadSaveReady := IsSet(_SaveFullConfigReady)
	if HadSaveReady
		SavedSaveReady := _SaveFullConfigReady
	Path := A_Temp . "\ergopti_ahk15_stale_canonicalization.toml"
	try FileDelete(Path)
	try {
		ConfigurationFile := Path
		CategoryEnabled := Map("TapHolds", true)
		Features := Map()
		ScriptInformation := Map("MagicKey", "*")
		ScriptShortcutAssignments := Map()
		KeyboardShortcutAssignments := Map()
		GestureAssignments := Map()
		_LLM_Menu_Loaded := false
		_DriverReady := true
		_SaveFullConfigReady := true
		AssertTrue(TOML_Write(false, Path, "category_enabled", "tap_holds"),
			"the targeted candidate write must reach disk")
		AssertEqual(0, TOML_Read(Path, "category_enabled", "tap_holds", -1),
			"a successful targeted write must not be reserialized from the stale live CategoryEnabled Map")
	} finally {
		ConfigurationFile := SavedPath
		CategoryEnabled := SavedCategories
		Features := SavedFeatures
		ScriptInformation := SavedScriptInformation
		if HadScriptAssignments
			ScriptShortcutAssignments := SavedScriptAssignments
		else
			ScriptShortcutAssignments := unset
		if HadKeyboardAssignments
			KeyboardShortcutAssignments := SavedKeyboardAssignments
		else
			KeyboardShortcutAssignments := unset
		if HadGestureAssignments
			GestureAssignments := SavedGestureAssignments
		else
			GestureAssignments := unset
		if HadLlmMenuLoaded
			_LLM_Menu_Loaded := SavedLlmMenuLoaded
		else
			_LLM_Menu_Loaded := unset
		if HadDriverReady
			_DriverReady := SavedDriverReady
		else
			_DriverReady := unset
		if HadSaveReady
			_SaveFullConfigReady := SavedSaveReady
		else
			_SaveFullConfigReady := unset
		try FileDelete(Path)
	}
}
Test("AHK-15-persistence: targeted commit survives stale live canonical state",
	_CPT_TargetedWriteCannotBeOverwrittenByStaleCanonicalState)





; =============================================
; =============================================
; ======= 2/ Deferred side-effect gates =======
; =============================================
; =============================================

_CPT_LocaleFailurePublishesAndSchedulesNothing() {
	global ConfigurationFile, _I18nLocale, _I18nCacheLoaded, _I18nFallbacksWarmed
	global _CPT_NotifyCalls, _CPT_TimerCalls
	SavedPath := ConfigurationFile
	SavedLocale := _I18nLocale
	SavedCacheLoaded := _I18nCacheLoaded
	SavedFallbacks := _I18nFallbacksWarmed
	ConfigurationFile := A_Temp . "\ergopti_ahk15_locale.toml"
	_I18nLocale := "en"
	_I18nCacheLoaded := true
	_I18nFallbacksWarmed := true
	_CPT_ResetConfigFakes(1)
	try {
		AssertFalse(I18nSetLocale("fr", _CPT_ConfigWriter, _CPT_Notify, _CPT_Timer))
		AssertEqual("en", _I18nLocale, "failed locale persistence must not publish the candidate")
		AssertTrue(_I18nCacheLoaded, "failed locale persistence must not invalidate the live cache")
		AssertTrue(_I18nFallbacksWarmed, "failed locale persistence must not invalidate fallbacks")
		AssertEqual(0, _CPT_TimerCalls, "failed locale persistence must not arm reload")
		AssertEqual(1, _CPT_NotifyCalls, "failed locale persistence must show one error")
	} finally {
		ConfigurationFile := SavedPath
		_I18nLocale := SavedLocale
		_I18nCacheLoaded := SavedCacheLoaded
		_I18nFallbacksWarmed := SavedFallbacks
	}
}
Test("AHK-15-persistence: locale failure publishes no state and arms no reload",
	_CPT_LocaleFailurePublishesAndSchedulesNothing)

_CPT_FirstBootFailureSchedulesNoElevatedWork() {
	global _CPT_NotifyCalls, _CPT_TimerCalls
	_CPT_ResetConfigFakes(1)
	AssertFalse(GestureConsumeAutoConfigureFlag(A_Temp . "\ergopti_ahk15_firstboot.toml",
		_CPT_ConfigWriter, _CPT_Notify, _CPT_Timer))
	AssertEqual(0, _CPT_TimerCalls, "failed marker clear must not schedule UAC/PnP work")
	AssertEqual(1, _CPT_NotifyCalls, "failed marker clear must show one error")
}
Test("AHK-15-persistence: first-boot marker failure schedules no side effect",
	_CPT_FirstBootFailureSchedulesNoElevatedWork)
