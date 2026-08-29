; tests/unit/test_config_persistence_transactions.ahk

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
	static CFG_VISIBLE := "wpm_visible"
	static CFG_X := "wpm_x"
	static CFG_Y := "wpm_y"
	static CFG_COLORS := "wpm_colors"
	static CFG_GRAPH := "wpm_graph"
}

class WPMWidget {
	static visible := false
	static pos_x := 0
	static pos_y := 0
	static use_colors := false
	static show_graph := false
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

_CPT_GestureFailureLeavesBothMapsUntouched(FailAt) {
	global ConfigurationFile, _CPT_ConfigWriteCalls, _CPT_ConfigUpdates, _CPT_NotifyCalls
	OriginalPath := ConfigurationFile
	Path := A_Temp . "\ergopti_ahk15_persistence.toml"
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
	_CPT_ResetConfigFakes(1)
	Returned := ConfigCommitUpdates("ignored.toml",
		[{ Section: "script", Key: "locale", Value: "fr" }],
		"the injected notifier failure", _CPT_ConfigWriter, _CPT_ThrowingNotify)
	AssertFalse(Returned,
		"a secondary notifier exception must not replace the writer's false status")
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

_CPT_BulkOffUsesOnlyTapHoldMasterGateStore() {
	global ConfigurationFile, Features, CategoryEnabled, TapHold, _IniCache
	global _ConfigDir, _AhkSubDir
	global GestureAssignments, KeyboardShortcutAssignments, ScriptShortcutAssignments
	global GESTURE_SLOTS, KEYBOARD_SHORTCUT_DEFAULTS, SCRIPT_SHORTCUT_SLOTS
	global CATEGORY_FOLLOWS_HOTSTRINGS_MASTER, _Stub_SentText
	global _ParseTomlCache, _TomlFileCache
	SavedPath := ConfigurationFile
	SavedConfigDir := _ConfigDir
	SavedAhkSubDir := _AhkSubDir
	SavedFeatures := Features
	SavedCategories := CategoryEnabled
	SavedTapHold := TapHold
	SavedIniCache := _IniCache
	SavedWpmVisible := WPMWidget.visible
	SavedWpmColors := WPMWidget.use_colors
	SavedWpmGraph := WPMWidget.show_graph
	HadGestureAssignments := IsSet(GestureAssignments)
	if HadGestureAssignments
		SavedGestureAssignments := GestureAssignments
	HadKeyboardAssignments := IsSet(KeyboardShortcutAssignments)
	if HadKeyboardAssignments
		SavedKeyboardAssignments := KeyboardShortcutAssignments
	HadScriptAssignments := IsSet(ScriptShortcutAssignments)
	if HadScriptAssignments
		SavedScriptAssignments := ScriptShortcutAssignments
	HadGestureSlots := IsSet(GESTURE_SLOTS)
	if HadGestureSlots
		SavedGestureSlots := GESTURE_SLOTS
	HadKeyboardDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS)
	if HadKeyboardDefaults
		SavedKeyboardDefaults := KEYBOARD_SHORTCUT_DEFAULTS
	HadScriptSlots := IsSet(SCRIPT_SHORTCUT_SLOTS)
	if HadScriptSlots
		SavedScriptSlots := SCRIPT_SHORTCUT_SLOTS
	HadCategoryFollowers := IsSet(CATEGORY_FOLLOWS_HOTSTRINGS_MASTER)
	if HadCategoryFollowers
		SavedCategoryFollowers := CATEGORY_FOLLOWS_HOTSTRINGS_MASTER
	ReloadEventsBefore := _Stub_SentText.Length
	UniqueSuffix := A_ScriptHwnd . "_" . A_TickCount
	ConfigPath := A_Temp . "\ergopti_ahk15_bulk_tap_hold_" . UniqueSuffix . ".toml"
	TapHoldDir := A_Temp . "\ergopti_ahk15_bulk_tap_hold_state_" . UniqueSuffix
	TapHoldPath := TapHoldDir . "\tap_hold.toml"
	TapHoldContent := "[tap_hold]`ninherit_defaults = false`n`n"
		. '[tap_hold.keys.caps_lock]`ntap_action = "enter"`n'
		. "time_activation_seconds = 0.25`n"
	try FileDelete(ConfigPath)
	try FileDelete(TapHoldPath)
	try {
		DirCreate(TapHoldDir)
		FileAppend(TapHoldContent, TapHoldPath, "UTF-8-RAW")
		OriginalTapHoldContent := FileRead(TapHoldPath, "UTF-8")
		ConfigurationFile := ConfigPath
		_ConfigDir := TapHoldDir . "\"
		_AhkSubDir := ""
		Features := Map("layout", Map("enabled", true))
		CategoryEnabled := Map("TapHolds", true)
		TapHold := LoadTapHoldToml(TapHoldPath)
		GestureAssignments := Map()
		KeyboardShortcutAssignments := Map()
		ScriptShortcutAssignments := Map()
		GESTURE_SLOTS := []
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		SCRIPT_SHORTCUT_SLOTS := []
		CATEGORY_FOLLOWS_HOTSTRINGS_MASTER := Map()
		_IniCache := Map()
		WPMWidget.visible := true
		WPMWidget.use_colors := true
		WPMWidget.show_graph := true

		Returned := ToggleAllFeatures(false)

		AssertTrue(Returned, "the single config.toml master-gate commit must complete")
		AssertEqual(0, TOML_Read(ConfigPath, "category_enabled", "tap_holds", -1),
			"config.toml must durably disable the TapHolds master gate")
		AssertEqual(OriginalTapHoldContent, FileRead(TapHoldPath, "UTF-8"),
			"bulk OFF must preserve the user's tap_hold.toml byte-for-byte")
		AssertEqual(0, TapHold["keys"].Count,
			"the disabled runtime candidate must expose no configured tap-hold key")
		AssertEqual(ReloadEventsBefore + 1, _Stub_SentText.Length,
			"the completed single-store transaction must request exactly one reload")
		AssertEqual("reload_preserving_suspend", _Stub_SentText[_Stub_SentText.Length].kind,
			"the bulk toggle must use the suspend-preserving reload boundary")

		ReloadedTapHold := LoadTapHoldToml(TapHoldPath)
		EnabledCategories := Map("TapHolds", true)
		EnabledGate := (Category) => _ConfigCandidateCategoryEnabled(EnabledCategories, Category)
		ApplyMasterGatesToFeatures(Map(), ReloadedTapHold, EnabledGate, 0)
		AssertEqual("enter", ReloadedTapHold["keys"]["caps_lock"]["tap_action"],
			"reloading with the master gate enabled must restore the preserved mapping")
	} finally {
		ConfigurationFile := SavedPath
		_ConfigDir := SavedConfigDir
		_AhkSubDir := SavedAhkSubDir
		Features := SavedFeatures
		CategoryEnabled := SavedCategories
		TapHold := SavedTapHold
		_IniCache := SavedIniCache
		WPMWidget.visible := SavedWpmVisible
		WPMWidget.use_colors := SavedWpmColors
		WPMWidget.show_graph := SavedWpmGraph
		if HadGestureAssignments
			GestureAssignments := SavedGestureAssignments
		else
			GestureAssignments := unset
		if HadKeyboardAssignments
			KeyboardShortcutAssignments := SavedKeyboardAssignments
		else
			KeyboardShortcutAssignments := unset
		if HadScriptAssignments
			ScriptShortcutAssignments := SavedScriptAssignments
		else
			ScriptShortcutAssignments := unset
		if HadGestureSlots
			GESTURE_SLOTS := SavedGestureSlots
		else
			GESTURE_SLOTS := unset
		if HadKeyboardDefaults
			KEYBOARD_SHORTCUT_DEFAULTS := SavedKeyboardDefaults
		else
			KEYBOARD_SHORTCUT_DEFAULTS := unset
		if HadScriptSlots
			SCRIPT_SHORTCUT_SLOTS := SavedScriptSlots
		else
			SCRIPT_SHORTCUT_SLOTS := unset
		if HadCategoryFollowers
			CATEGORY_FOLLOWS_HOTSTRINGS_MASTER := SavedCategoryFollowers
		else
			CATEGORY_FOLLOWS_HOTSTRINGS_MASTER := unset
		while (_Stub_SentText.Length > ReloadEventsBefore)
			_Stub_SentText.Pop()
		if _ParseTomlCache.Has(ConfigPath)
			_ParseTomlCache.Delete(ConfigPath)
		if _TomlFileCache.Has(TapHoldPath)
			_TomlFileCache.Delete(TapHoldPath)
		try FileDelete(ConfigPath)
		try FileDelete(TapHoldPath)
		try DirDelete(TapHoldDir)
	}
}
Test("AHK-15-persistence: bulk OFF uses one durable master gate (bulk-tap-hold-single-store)",
	_CPT_BulkOffUsesOnlyTapHoldMasterGateStore)





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





; ==========================================
; ==========================================
; ======= 3/ Suspend marker hand-off =======
; ==========================================
; ==========================================

global _CPT_MarkerExists := false
global _CPT_ClaimExists := false
global _CPT_PendingExists := false
global _CPT_HandoffWriteOk := true
global _CPT_HandoffMoveOk := true
global _CPT_HandoffDeleteOk := true
global _CPT_ReloadCalls := 0
global _CPT_ToggleCalls := 0
global _CPT_HandoffFailures := 0
global _CPT_BeforeToggleCalls := 0
global _CPT_HandoffMoveCalls := 0
global _CPT_HandoffCancelCalls := 0
global _CPT_HandoffProbeThrows := false
global _CPT_HandoffDeleteThrows := false

_CPT_ResetHandoffFakes() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_PendingExists
	global _CPT_HandoffWriteOk, _CPT_HandoffMoveOk
	global _CPT_HandoffDeleteOk, _CPT_ReloadCalls, _CPT_ToggleCalls
	global _CPT_HandoffFailures, _CPT_BeforeToggleCalls, _CPT_HandoffMoveCalls
	global _CPT_HandoffCancelCalls, _CPT_HandoffProbeThrows, _CPT_HandoffDeleteThrows
	_CPT_MarkerExists := false
	_CPT_ClaimExists := false
	_CPT_PendingExists := false
	_CPT_HandoffWriteOk := true
	_CPT_HandoffMoveOk := true
	_CPT_HandoffDeleteOk := true
	_CPT_ReloadCalls := 0
	_CPT_ToggleCalls := 0
	_CPT_HandoffFailures := 0
	_CPT_BeforeToggleCalls := 0
	_CPT_HandoffMoveCalls := 0
	_CPT_HandoffCancelCalls := 0
	_CPT_HandoffProbeThrows := false
	_CPT_HandoffDeleteThrows := false
}

_CPT_HandoffPrepare(Path) {
	global _CPT_HandoffWriteOk, _CPT_PendingExists
	if _CPT_HandoffWriteOk
		_CPT_PendingExists := true
	return _CPT_HandoffWriteOk
}

_CPT_HandoffCommit(Path) {
	global _CPT_PendingExists, _CPT_MarkerExists, _CPT_HandoffMoveOk
	if !_CPT_PendingExists or !_CPT_HandoffMoveOk
		return 0
	_CPT_PendingExists := false
	_CPT_MarkerExists := true
	return 1
}

_CPT_HandoffExists(Path) {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffProbeThrows
	if _CPT_HandoffProbeThrows
		throw OSError(5, A_ThisFunc, "injected access-denied probe")
	return (Path == "marker.claim") ? _CPT_ClaimExists : _CPT_MarkerExists
}

_CPT_HandoffMove(Source, Destination, Overwrite) {
	global _CPT_HandoffMoveOk, _CPT_MarkerExists, _CPT_ClaimExists
	global _CPT_HandoffMoveCalls
	_CPT_HandoffMoveCalls += 1
	if !_CPT_MarkerExists or !_CPT_HandoffMoveOk
		return false
	_CPT_MarkerExists := false
	_CPT_ClaimExists := true
	return true
}

_CPT_HandoffDelete(Path) {
	global _CPT_HandoffDeleteOk, _CPT_MarkerExists, _CPT_ClaimExists
	global _CPT_HandoffDeleteThrows
	if _CPT_HandoffDeleteThrows
		throw OSError(5, A_ThisFunc, "injected access-denied delete")
	if _CPT_HandoffDeleteOk {
		if (Path == "marker.claim")
			_CPT_ClaimExists := false
		else
			_CPT_MarkerExists := false
	}
	return _CPT_HandoffDeleteOk
}

_CPT_Reload() {
	global _CPT_ReloadCalls
	_CPT_ReloadCalls += 1
	return 1
}

_CPT_RefusedReload() {
	global _CPT_ReloadCalls
	_CPT_ReloadCalls += 1
	return false
}

_CPT_HandoffCancel(Path) {
	global _CPT_HandoffCancelCalls, _CPT_PendingExists, _CPT_HandoffDeleteOk
	_CPT_HandoffCancelCalls += 1
	if _CPT_HandoffDeleteOk
		_CPT_PendingExists := false
	return _CPT_HandoffDeleteOk ? 1 : 0
}

_CPT_Toggle() {
	global _CPT_ToggleCalls
	_CPT_ToggleCalls += 1
}

_CPT_HandoffFailure(Stage, Path) {
	global _CPT_HandoffFailures
	_CPT_HandoffFailures += 1
}

_CPT_BeforeToggle() {
	global _CPT_BeforeToggleCalls
	_CPT_BeforeToggleCalls += 1
}

_CPT_MarkerPublicationFailureAbortsReload() {
	global _CPT_HandoffWriteOk, _CPT_ReloadCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_HandoffWriteOk := false
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare, _CPT_Reload,
		0, _CPT_HandoffFailure))
	AssertEqual(0, _CPT_ReloadCalls, "publication failure must abort Reload")
	AssertEqual(1, _CPT_HandoffFailures, "publication failure must be surfaced exactly once")
}
Test("AHK-15-persistence: suspend marker publication failure aborts reload",
	_CPT_MarkerPublicationFailureAbortsReload)

_CPT_ReturnedReloadIsFailureAndRetractsMarker() {
	global _CPT_ReloadCalls, _CPT_MarkerExists, _CPT_PendingExists
	global _CPT_HandoffCancelCalls
	_CPT_ResetHandoffFakes()
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare,
		_CPT_RefusedReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
	AssertEqual(1, _CPT_ReloadCalls)
	AssertEqual(1, _CPT_HandoffCancelCalls,
		"a returned/refused Reload must retract pause intent exactly once")
	AssertFalse(_CPT_MarkerExists,
		"a refused Reload must never publish live pause intent")
	AssertFalse(_CPT_PendingExists,
		"the normal refusal path should clean its inert preparation")
}
Test("AHK-15-persistence: refused reload retracts its suspend marker",
	_CPT_ReturnedReloadIsFailureAndRetractsMarker)

_CPT_SuspendTempMarker(Slug) {
	return A_Temp . "\ergopti_suspend_" . DllCall("GetCurrentProcessId")
		. "_" . A_TickCount . "_" . Slug . ".marker"
}

_CPT_SuspendTempCleanup(Path) {
	for Candidate in [Path . ".pending.stage", Path . ".pending",
			Path . ".claim", Path]
		FSDelete(Candidate)
}

_CPT_SuspendPreparationIsInertAndDurable() {
	Path := _CPT_SuspendTempMarker("prepare")
	_CPT_SuspendTempCleanup(Path)
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		AssertFalse(FSExists(Path),
			"preflight must not create boot-consumable pause authority")
		AssertTrue(FSExists(Path . ".pending"))
		AssertEqual("1", FSRead(Path . ".pending"),
			"the complete durable stage must survive exact readback")
		AssertFalse(FSExists(Path . ".pending.stage"),
			"atomic preparation must retire its scratch path")
	} finally _CPT_SuspendTempCleanup(Path)
}
Test("AHK-15-persistence: suspend preflight creates only durable inert state "
	. "(suspend-handoff-inert-prepare)",
	_CPT_SuspendPreparationIsInertAndDurable)

_CPT_SuspendRefusalCleanupFailureStaysInert() {
	global _CPT_MarkerExists, _CPT_PendingExists, _CPT_HandoffDeleteOk
	global _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffReload(true, "marker", _CPT_HandoffPrepare,
		_CPT_RefusedReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
	AssertFalse(_CPT_MarkerExists,
		"even failed refusal cleanup must leave no live pause marker")
	AssertTrue(_CPT_PendingExists,
		"the injected cleanup failure may retain only inert debris")
	AssertEqual(1, _CPT_HandoffFailures,
		"inert cleanup failure must remain visible")
}
Test("AHK-15-persistence: refused reload cleanup debris remains inert "
	. "(suspend-handoff-refusal-inert)",
	_CPT_SuspendRefusalCleanupFailureStaysInert)

_CPT_SuspendTerminalCommitPublishesExactlyOnce() {
	Path := _CPT_SuspendTempMarker("terminal")
	_CPT_SuspendTempCleanup(Path)
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\suspend-terminal.toml"])
	AssertTrue(Bundle is Object)
	Record := false
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		Record := ReloadTerminalHandoffPrepare(Bundle, 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertTrue(Record is Map)
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertEqual(Record, Claimed)
		AssertTrue(ReloadTerminalHandoffCommit(Claimed))
		AssertTrue(FSExists(Path),
			"only accepted terminal authority may publish the live marker")
		AssertFalse(FSExists(Path . ".pending"))
		AssertFalse(ReloadTerminalHandoffCommit(Claimed),
			"the same terminal record must not publish twice")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed))
	} finally {
		ReloadTerminalHandoffCancel(Record)
		_ConfigWriteTerminalRelease(Bundle)
		_CPT_SuspendTempCleanup(Path)
	}
}
Test("AHK-15-persistence: terminal acceptance publishes pause exactly once "
	. "(suspend-handoff-terminal-once)",
	_CPT_SuspendTerminalCommitPublishesExactlyOnce)

_CPT_RefusedPausedReloadCanRetrySameTerminalBundle() {
	Path := _CPT_SuspendTempMarker("terminal-retry")
	_CPT_SuspendTempCleanup(Path)
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\suspend-terminal-retry.toml"])
	AssertTrue(Bundle is Object)
	First := false
	Second := false
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		First := ReloadTerminalHandoffPrepare(Bundle, 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertTrue(First is Map)
		AssertEqual(First, ReloadTerminalHandoffClaim("Reload"))
		AssertTrue(ReloadTerminalHandoffCancel(First),
			"a late refusal must cancel the first terminal claim")
		AssertFalse(FSExists(Path))
		AssertFalse(FSExists(Path . ".pending"),
			"the refused paused attempt must leave no live or pending marker")

		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		Second := ReloadTerminalHandoffPrepare(Bundle, 0,
			SuspendHandoffCommit.Bind(Path, FSRead, FSAtomicMoveReplace),
			SuspendHandoffAbort.Bind(Path, FSExists, FSDelete))
		AssertTrue(Second is Map,
			"the same retained terminal bundle must be preparable after refusal")
		AssertEqual(Second, ReloadTerminalHandoffClaim("Reload"),
			"the same retained bundle must be claimable on the second Reload")
		AssertTrue(ReloadTerminalHandoffCommit(Second))
		AssertTrue(FSExists(Path),
			"the retried accepted Reload must publish pause intent")
		AssertTrue(ReloadTerminalHandoffFinish(Second))
	} finally {
		ReloadTerminalHandoffCancel(Second)
		ReloadTerminalHandoffCancel(First)
		_ConfigWriteTerminalRelease(Bundle)
		_CPT_SuspendTempCleanup(Path)
	}
}
Test("AHK-15-persistence: refused paused Reload can reuse retained barrier "
	. "(reload-terminal-retained-retry)",
	_CPT_RefusedPausedReloadCanRetrySameTerminalBundle)

_CPT_CriticalProbe(State, Name, Result := 1) {
	State[Name] := A_IsCritical
	return Result
}

_CPT_TerminalCallbacksRunOutsideInheritedCritical() {
	State := Map()
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-critical.toml"])
	AssertTrue(Bundle is Object)
	PreviousCritical := Critical("On")
	try {
		Record := ReloadTerminalHandoffPrepare(Bundle,
			_CPT_CriticalProbe.Bind(State, "success", 1),
			_CPT_CriticalProbe.Bind(State, "commit", 1),
			_CPT_CriticalProbe.Bind(State, "abort", 1))
		AssertTrue(Record is Map)
		AssertEqual(Record, ReloadTerminalHandoffClaim("Reload"))
		AssertTrue(ReloadTerminalHandoffCommit(Record))
		AssertTrue(ReloadTerminalHandoffFinish(Record,
			_CPT_CriticalProbe.Bind(State, "before_success", 1)))
		AssertEqual(0, State["commit"])
		AssertEqual(0, State["before_success"])
		AssertEqual(0, State["success"])
		AssertTrue(A_IsCritical != 0,
			"terminal callback wrappers must restore inherited Critical")

		Record := ReloadTerminalHandoffPrepare(Bundle, 0, 0,
			_CPT_CriticalProbe.Bind(State, "abort", 1))
		AssertTrue(Record is Map)
		AssertTrue(ReloadTerminalHandoffCancel(Record))
		AssertEqual(0, State["abort"])
		AssertTrue(A_IsCritical != 0)

		InvokeResult := ReloadTerminalInvoke(Bundle, 0,
			_CPT_CriticalProbe.Bind(State, "invoke", 0))
		AssertFalse(InvokeResult)
		AssertEqual(0, State["invoke"])
		AssertTrue(A_IsCritical != 0)
	} finally {
		Critical(PreviousCritical)
		_ConfigWriteTerminalRelease(Bundle)
	}
}
Test("AHK-15-persistence: terminal callbacks drop and restore inherited Critical "
	. "(reload-terminal-critical-boundaries)",
	_CPT_TerminalCallbacksRunOutsideInheritedCritical)

_CPT_SuspendBootDiscardsPendingWithoutToggle() {
	global _CPT_ToggleCalls
	Path := _CPT_SuspendTempMarker("boot-debris")
	_CPT_SuspendTempCleanup(Path)
	_CPT_ToggleCalls := 0
	try {
		AssertTrue(SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
			FSAtomicMoveReplace, FSDelete))
		AssertTrue(SuspendHandoffDiscardPending(Path, FSExists, FSDelete))
		AssertTrue(SuspendHandoffConsume(Path, false, FSExists, FSMove,
			FSDelete, _CPT_Toggle))
		AssertEqual(0, _CPT_ToggleCalls,
			"boot must never interpret pending debris as pause intent")
	} finally _CPT_SuspendTempCleanup(Path)
}
Test("AHK-15-persistence: boot discards pending pause debris without toggling "
	. "(suspend-handoff-boot-discard)",
	_CPT_SuspendBootDiscardsPendingWithoutToggle)

_CPT_SuspendMarkerFollowsStableLocator() {
	PathsFile := "D:\stable-locator\paths.toml"
	Expected := "D:\stable-locator\suspend_restore.marker"
	AssertEqual(Expected, SuspendHandoffMarkerPath(PathsFile))
	; Config relocation is intentionally absent from this API: only the stable
	; locator decides where both the old and replacement process look.
	AssertEqual(Expected, SuspendHandoffMarkerPath(PathsFile))
}
Test("AHK-15-persistence: suspend marker follows stable paths locator "
	. "(suspend-handoff-stable-locator)",
	_CPT_SuspendMarkerFollowsStableLocator)

global _CPT_TerminalSuccessCalls := 0
global _CPT_TerminalClaimCalls := 0
global _CPT_TerminalEvents := []
global _CPT_TerminalCommitOk := true

_CPT_TerminalSuccess() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalEvents
	_CPT_TerminalSuccessCalls += 1
	_CPT_TerminalEvents.Push("success")
}

_CPT_TerminalCommit() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	_CPT_TerminalEvents.Push("commit")
	return _CPT_TerminalCommitOk ? 1 : 0
}

_CPT_TerminalTeardown() {
	global _CPT_TerminalEvents
	_CPT_TerminalEvents.Push("teardown")
}

_CPT_TerminalAbort() {
	global _CPT_TerminalEvents
	_CPT_TerminalEvents.Push("abort")
	return 1
}

_CPT_TerminalLateRefusal() {
	global _CPT_TerminalClaimCalls
	Record := ReloadTerminalHandoffClaim("Reload")
	if (Record is Map)
		_CPT_TerminalClaimCalls += 1
	; Models a later OnExit gate returning 1: ownership was claimed, but terminal
	; success and UI teardown were never authorized.
	return false
}

_CPT_TerminalAccepted() {
	global _CPT_TerminalClaimCalls
	Record := ReloadTerminalHandoffClaim("Reload")
	if !(Record is Map)
		return false
	_CPT_TerminalClaimCalls += 1
	return ReloadTerminalHandoffFinish(Record)
}

_CPT_TerminalCommitRefused() {
	global _CPT_TerminalClaimCalls
	Record := ReloadTerminalHandoffClaim("Reload")
	if !(Record is Map)
		return false
	_CPT_TerminalClaimCalls += 1
	return ReloadTerminalHandoffCommit(Record)
}

_CPT_TerminalBundleBlocksEverySiblingPath() {
	ConfigPath := "C:\ergopti-tests\A\config.toml"
	CandidatePath := "C:\ergopti-tests\B\config.toml"
	OverridesPath := "C:\ergopti-tests\A\hotstrings_overrides.toml"
	Bundle := _ConfigWriteTerminalTryAcquire([ConfigPath, CandidatePath])
	AssertTrue(Bundle is Object)
	try {
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, ConfigPath) is Object)
		AssertTrue(_ConfigWriteLeaseSelectOwner(Bundle, CandidatePath) is Object)
		AssertFalse(_ConfigWriteLeaseTryAcquire(OverridesPath,
			"sibling-writer") is Object,
			"a locator transition must block every sibling-path config writer")
	} finally _ConfigWriteTerminalRelease(Bundle)
	Sibling := _ConfigWriteLeaseTryAcquire(OverridesPath, "after-transition")
	AssertTrue(Sibling is Object)
	AssertTrue(_ConfigWriteLeaseRelease(Sibling))
}
Test("AHK-15-persistence: terminal bundle blocks sibling-path writers",
	_CPT_TerminalBundleBlocksEverySiblingPath)

_CPT_TerminalClaimRequiresAuthorizationAndIsSingleUse() {
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-config.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"shutdown cannot borrow an unannounced transition")
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
		AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle),
			"the exact terminal bundle may be claimed only once")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("AHK-15-persistence: terminal shutdown claim is authorized and single-use",
	_CPT_TerminalClaimRequiresAuthorizationAndIsSingleUse)

_CPT_UnrelatedExitCannotConsumeReloadAuthorization() {
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\reason-bound-reload.toml"])
	AssertTrue(Bundle is Object)
	Record := false
	try {
		Record := ReloadTerminalHandoffPrepare(Bundle)
		AssertTrue(Record is Map)
		AssertFalse(ReloadTerminalHandoffClaim("Exit"),
			"an ordinary ExitApp must not borrow a pending Reload transaction")
		AssertEqual("authorized", Record["state"],
			"a wrong reason must leave the exact Reload retry claimable")
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertTrue(Claimed is Map)
		AssertEqual(Record, Claimed)
		AssertFalse(ReloadTerminalHandoffClaim("Reload"),
			"the exact Reload reason may still claim only once")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed))
	} finally {
		ReloadTerminalHandoffCancel(Record)
		_ConfigWriteTerminalRelease(Bundle)
	}
}
Test("AHK-15-persistence: unrelated Exit cannot consume Reload authorization "
	. "(reload-terminal-reason-bound)",
	_CPT_UnrelatedExitCannotConsumeReloadAuthorization)

_CPT_LateShutdownRefusalCannotReportReloadSuccess() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\refused-reload.toml"])
	AssertTrue(Bundle is Object)
	try {
		TerminalReload := ReloadTerminalInvoke.Bind(Bundle,
			_CPT_TerminalSuccess, _CPT_TerminalLateRefusal)
		AssertFalse(SuspendHandoffReload(false, "", _CPT_HandoffPrepare,
			TerminalReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(0, _CPT_TerminalSuccessCalls,
			"late OnExit refusal must leave retry UI untouched")
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("AHK-15-persistence: late OnExit refusal stays false and preserves retry UI "
	. "(reload-terminal-late-refusal)",
	_CPT_LateShutdownRefusalCannotReportReloadSuccess)

_CPT_TerminalSuccessRunsOnlyAfterClaimFinish() {
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\accepted-reload.toml"])
	AssertTrue(Bundle is Object)
	try {
		TerminalReload := ReloadTerminalInvoke.Bind(Bundle,
			_CPT_TerminalSuccess, _CPT_TerminalAccepted)
		AssertTrue(SuspendHandoffReload(false, "", _CPT_HandoffPrepare,
			TerminalReload, 0, _CPT_HandoffFailure, _CPT_HandoffCancel))
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(1, _CPT_TerminalSuccessCalls)
	} finally _ConfigWriteTerminalRelease(Bundle)
}
Test("AHK-15-persistence: terminal callback follows the final shutdown gate "
	. "(reload-terminal-success)",
	_CPT_TerminalSuccessRunsOnlyAfterClaimFinish)

_CPT_TerminalCommitPrecedesSuccess() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	_CPT_TerminalEvents := []
	_CPT_TerminalCommitOk := true
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-commit-order.toml"])
	AssertTrue(Bundle is Object)
	Record := false
	try {
		Record := ReloadTerminalHandoffPrepare(Bundle, _CPT_TerminalSuccess,
			_CPT_TerminalCommit, _CPT_TerminalAbort)
		AssertTrue(Record is Map)
		Claimed := ReloadTerminalHandoffClaim("Reload")
		AssertEqual(Record, Claimed)
		AssertTrue(ReloadTerminalHandoffCommit(Claimed))
		AssertEqual("committed", Record["state"])
		AssertEqual(1, _CPT_TerminalEvents.Length)
		AssertEqual("commit", _CPT_TerminalEvents[1],
			"durable terminal publication must precede UI success")
		AssertTrue(ReloadTerminalHandoffFinish(Claimed,
			_CPT_TerminalTeardown))
		AssertEqual(3, _CPT_TerminalEvents.Length)
		AssertEqual("teardown", _CPT_TerminalEvents[2],
			"destructive teardown must follow durable commit")
		AssertEqual("success", _CPT_TerminalEvents[3],
			"UI success must follow terminal teardown")
	} finally {
		ReloadTerminalHandoffCancel(Record)
		_ConfigWriteTerminalRelease(Bundle)
	}
}
Test("AHK-15-persistence: terminal commit precedes success "
	. "(reload-terminal-commit-order)", _CPT_TerminalCommitPrecedesSuccess)

_CPT_TerminalCommitFailureAbortsWithoutSuccess() {
	global _CPT_TerminalEvents, _CPT_TerminalCommitOk
	global _CPT_TerminalSuccessCalls, _CPT_TerminalClaimCalls
	_CPT_TerminalEvents := []
	_CPT_TerminalCommitOk := false
	_CPT_TerminalSuccessCalls := 0
	_CPT_TerminalClaimCalls := 0
	Bundle := _ConfigWriteTerminalTryAcquire(
		["C:\ergopti-tests\terminal-commit-failure.toml"])
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(ReloadTerminalInvoke(Bundle, _CPT_TerminalSuccess,
			_CPT_TerminalCommitRefused, _CPT_TerminalCommit,
			_CPT_TerminalAbort))
		AssertEqual(1, _CPT_TerminalClaimCalls)
		AssertEqual(0, _CPT_TerminalSuccessCalls,
			"a failed terminal commit must never report success")
		AssertEqual(2, _CPT_TerminalEvents.Length)
		AssertEqual("commit", _CPT_TerminalEvents[1])
		AssertEqual("abort", _CPT_TerminalEvents[2],
			"returned refusal must abort the inert transition")
	} finally {
		_CPT_TerminalCommitOk := true
		_ConfigWriteTerminalRelease(Bundle)
	}
}
Test("AHK-15-persistence: failed terminal commit aborts without success "
	. "(reload-terminal-commit-failure)",
	_CPT_TerminalCommitFailureAbortsWithoutSuccess)

_CPT_MarkerDeleteFailureNeverToggles() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteOk, _CPT_ToggleCalls
	global _CPT_HandoffFailures, _CPT_BeforeToggleCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(0, _CPT_ToggleCalls, "failed claim consumption must not toggle suspend")
	AssertEqual(0, _CPT_BeforeToggleCalls, "failed claim consumption must not report a restore")
	AssertEqual(1, _CPT_HandoffFailures, "failed claim consumption must be surfaced exactly once")
	AssertTrue(_CPT_ClaimExists, "failed deletion must retain a restart-stable claim for retry")
}
Test("AHK-15-persistence: suspend marker delete failure never toggles",
	_CPT_MarkerDeleteFailureNeverToggles)

_CPT_StrictProbeErrorRetainsSourceForRetry() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffProbeThrows
	global _CPT_ToggleCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffProbeThrows := true
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertTrue(_CPT_MarkerExists, "a failed probe must retain the source intent")
	AssertFalse(_CPT_ClaimExists, "a failed probe must not invent a claim")
	AssertEqual(0, _CPT_ToggleCalls, "a failed probe must never toggle suspend")
	AssertEqual(1, _CPT_HandoffFailures, "a probe error must be surfaced exactly once")

	_CPT_HandoffProbeThrows := false
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "the retained source must remain retryable")
}
Test("AHK-006: strict marker probe errors are loud and retryable",
	_CPT_StrictProbeErrorRetainsSourceForRetry)

_CPT_StrictDeleteErrorRetainsClaimForRetry() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteThrows
	global _CPT_ToggleCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteThrows := true
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the source must remain atomically claimed")
	AssertTrue(_CPT_ClaimExists, "a failed delete must retain the stable claim")
	AssertEqual(0, _CPT_ToggleCalls, "a failed delete must never toggle suspend")
	AssertEqual(1, _CPT_HandoffFailures, "a delete error must be surfaced exactly once")

	_CPT_HandoffDeleteThrows := false
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "the retained claim must remain retryable")
}
Test("AHK-006: strict marker delete errors are loud and retryable",
	_CPT_StrictDeleteErrorRetainsClaimForRetry)

_CPT_ConsumedMarkerTogglesExactlyOnce() {
	global _CPT_MarkerExists, _CPT_ToggleCalls, _CPT_HandoffFailures
	global _CPT_BeforeToggleCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	; The atomic move made the source absent, so a repeated boot sees no marker.
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "one published marker must toggle exactly once")
	AssertEqual(1, _CPT_BeforeToggleCalls, "the restore lifecycle must run exactly once")
	AssertEqual(0, _CPT_HandoffFailures)
}
Test("AHK-15-persistence: an atomically consumed marker toggles exactly once",
	_CPT_ConsumedMarkerTogglesExactlyOnce)

_CPT_DeleteFailureRetriesStableClaimExactlyOnce() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_HandoffDeleteOk
	global _CPT_ToggleCalls, _CPT_HandoffFailures, _CPT_HandoffMoveCalls
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_HandoffDeleteOk := false
	AssertFalse(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the source must remain atomically claimed")
	AssertTrue(_CPT_ClaimExists, "the durable claim must survive the failed delete")
	AssertEqual(0, _CPT_ToggleCalls, "a failed consume must not restore pause early")

	_CPT_HandoffDeleteOk := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_HandoffMoveCalls,
		"retry must resume the retained claim instead of requiring the vanished source")
	AssertEqual(1, _CPT_ToggleCalls, "the retained claim must restore pause exactly once")
	AssertEqual(1, _CPT_HandoffFailures, "only the original failed consume is reported")

	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls, "a consumed claim must not replay on a later boot")
}
Test("AHK-15-persistence: failed claim deletion retries once on the next boot",
	_CPT_DeleteFailureRetriesStableClaimExactlyOnce)

_CPT_SourceAndClaimCoalesceIntoOneRestore() {
	global _CPT_MarkerExists, _CPT_ClaimExists, _CPT_ToggleCalls
	global _CPT_HandoffMoveCalls, _CPT_HandoffFailures
	_CPT_ResetHandoffFakes()
	_CPT_MarkerExists := true
	_CPT_ClaimExists := true
	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertFalse(_CPT_MarkerExists, "the duplicate source intent must be coalesced")
	AssertFalse(_CPT_ClaimExists, "the retained claim must be consumed")
	AssertEqual(0, _CPT_HandoffMoveCalls, "an existing claim already owns the transition")
	AssertEqual(1, _CPT_ToggleCalls, "two suspend intents still describe one desired state")
	AssertEqual(0, _CPT_HandoffFailures)

	AssertTrue(SuspendHandoffConsume("marker", false,
		_CPT_HandoffExists, _CPT_HandoffMove, _CPT_HandoffDelete, _CPT_Toggle,
		_CPT_BeforeToggle, _CPT_HandoffFailure))
	AssertEqual(1, _CPT_ToggleCalls,
		"coalesced source and claim must not replay on the following boot")
}
Test("AHK-15-persistence: source and retained claim coalesce into one restore",
	_CPT_SourceAndClaimCoalesceIntoOneRestore)
