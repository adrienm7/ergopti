; tests/unit/settings/engine/persistence/test_transactions.ahk

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

#Include ../../../../support/metrics/wpm_widget_state_contract.ahk

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

; A delegated data-clone observation models one ordinary AHK interruption after
; the real clone is complete. Ownership, codecs, writers and dispatcher gates
; are never replaced. The same second menu action must survive either ordering.
_GCPO_Arm(State, Callback, DelayMs) {
	State.Timers.Push(Callback)
	State.Arms += 1
	return TimerArmOneShotMs(Callback, DelayMs)
}

_GCPO_B(State, *) {
	global GestureAssignments, GestureActionParameters
	if !State.Active
		return false
	State.BCalls += 1
	if State.Mode == "parameter"
		State.BResult := GestureSetActionParameter("gesture__tap_4", "open_url", "https://new-b.example/")
	else if State.Mode == "assignment"
		State.BResult := _GestureCommitAssignment(&GestureAssignments, &GestureActionParameters,
			"gestures", "tap_4", "open_url", Map("has_value", true,
				"key", "gesture__tap_4__open_url", "value", "https://new-b.example/"))
	else
		State.BResult := CapsWordAutoOffStore("shortcuts.caps_word.pointer.left_click", true)
	return State.BResult
}

_GCPO_ObserveClone(State, This, Args*) {
	State.Depth += 1
	try Copy := Func.Prototype.Call.Call(This, Args*)
	finally State.Depth -= 1
	if State.Active && !State.Fired && State.Depth == 0 {
		State.Fired := true
		State.BusyAtClone := MenuCommandConfigBusy()
		; Real menu admission executes B now outside a lease, or schedules the
		; same B on its genuine native timer while an owned builder is active.
		State.DispatchResult := MenuCommandRun(_GCPO_B.Bind(State), [], 0, 0, _GCPO_Arm.Bind(State))
		State.BCallsAtClone := State.BCalls
	}
	return Copy
}

_GCPO_Run(Mode) {
	global ConfigurationFile, GestureAssignments, GestureActionParameters, _MenuStartupCommands
	global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
	AssertTrue((_MenuStartupCommands is Integer) && _MenuStartupCommands == 0,
		"This command fixture cannot adopt another startup's pending menu intentions")
	AssertFalse(_ConfigWriteTerminalIsActive())
	AssertFalse(MenuCommandConfigBusy(), "The actual dispatcher must begin without an inherited writer or reader")
	Saved := {Path: ConfigurationFile, Assignments: GestureAssignments, Parameters: GestureActionParameters,
		CapsValues: CapsWordAutoOff.Values, CapsPolicy: CapsWordAutoOff.Configured,
		Critical: A_IsCritical, Suspended: A_IsSuspended}
	Fixture := _ScopeOwnerFixture('[gestures]`ntap_3 = "copy"`ntap_4 = "paste"`n'
		. '[action_parameters]`ngesture__tap_3__open_url = "https://old-a.example/"`n'
		. 'gesture__tap_4__open_url = "https://old-b.example/"`n'
		. '[shortcuts.caps_word]`nidle_timeout_seconds = 2`n'
		. '[shortcuts.caps_word.pointer]`nleft_click = false`n')
	; The generic ManifestCloneValue belongs to the native schema owner's
	; integrity graph. Observe only the actual CapsWord value-clone API so
	; schema admission and its canonical clone remain untouched.
	Owner := Mode == "capsword" ? CapsWordAutoOffValues : _GestureCloneActionParameters
	HadCall := Object.Prototype.HasOwnProp.Call(Owner, "Call")
	SavedCall := HadCall ? Object.Prototype.GetOwnPropDesc.Call(Owner, "Call") : false
	State := {Mode: Mode, Active: true, Fired: false, Depth: 0, Timers: [], Arms: 0,
		BusyAtClone: false, BCalls: 0, BCallsAtClone: 0, BResult: false, DispatchResult: ""}
	try {
		Critical("Off"), Suspend(false)
		ConfigurationFile := Fixture.path
		GestureAssignments := Map("tap_3", "copy", "tap_4", "paste")
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["gesture__tap_3__open_url"] := "https://old-a.example/"
		GestureActionParameters["gesture__tap_4__open_url"] := "https://old-b.example/"
		if Mode == "capsword" {
			CapsWordAutoOffReadConfig(ParseTomlFile(Fixture.path))
			AssertEqual(2, CapsWordAutoOffValues()["idle_timeout_seconds"])
		}
		Object.Prototype.DefineProp.Call(Owner, "Call", {Call: _GCPO_ObserveClone.Bind(State)})
		if Mode == "parameter"
			AResult := GestureSetActionParameter("gesture__tap_3", "open_url", "https://new-a.example/")
		else if Mode == "assignment"
			AResult := _GestureCommitAssignment(&GestureAssignments, &GestureActionParameters,
				"gestures", "tap_3", "open_url", Map("has_value", true,
					"key", "gesture__tap_3__open_url", "value", "https://new-a.example/"))
		else
			AResult := CapsWordAutoOffStore(ConfigKey.SHORTCUTS_CAPS_WORD_IDLE_TIMEOUT_SECONDS, 3)
		_TestPrint("# cached-candidate-entry mode=" . Mode . " a_result=" . AResult
			. " observed=" . State.Fired . " busy_at_clone=" . State.BusyAtClone
			. " b_calls_at_clone=" . State.BCallsAtClone . " b_result=" . State.BResult)
		AssertTrue(AResult, "The actual first writer must acknowledge its private durable mutation")
		AssertTrue(State.Fired, "The real candidate clone must pass through its delegated observation")
		Started := A_TickCount
		while State.BCalls == 0 && TickElapsed(Started) < 3000
			Sleep(5)
		AssertEqual(1, State.BCalls, "The genuine admitted/deferred second menu command must run exactly once")
		AssertTrue(State.BResult, "The second actual default writer must also acknowledge durability")
		Parsed := ParseTomlFile(Fixture.path)
		if Mode == "capsword" {
			Durable := CapsWordAutoOffReadValues(Parsed)
			Runtime := CapsWordAutoOffValues()
			_TestPrint("# cached-candidate-owner mode=" . Mode . " busy_at_clone=" . State.BusyAtClone
				. " b_calls_at_clone=" . State.BCallsAtClone . " native_timer_arms=" . State.Arms
				. " durable_idle=" . Durable["idle_timeout_seconds"] . " ram_idle=" . Runtime["idle_timeout_seconds"]
				. " durable_left=" . Durable["pointer"]["left_click"] . " ram_left=" . Runtime["pointer"]["left_click"])
			AssertEqual(3, Durable["idle_timeout_seconds"])
			AssertTrue(Durable["pointer"]["left_click"])
			AssertEqual(3, Runtime["idle_timeout_seconds"])
			AssertTrue(Runtime["pointer"]["left_click"], "Publishing A's stale candidate cannot discard B's acknowledged CapsWord preference")
			AssertEqual(3000, CapsWordAutoOff.Configured["idle_ms"])
			AssertTrue(CapsWordAutoOff.Configured["pointer"]["left_click"])
		} else {
			DurableA := IniCacheGet(Parsed, "action_parameters", "gesture__tap_3__open_url")
			DurableB := IniCacheGet(Parsed, "action_parameters", "gesture__tap_4__open_url")
			_TestPrint("# cached-candidate-owner mode=" . Mode . " busy_at_clone=" . State.BusyAtClone
				. " b_calls_at_clone=" . State.BCallsAtClone . " native_timer_arms=" . State.Arms
				. " disk_b_new=" . (DurableB == "https://new-b.example/")
				. " ram_b_new=" . (GestureActionParameters["gesture__tap_4__open_url"] == "https://new-b.example/"))
			AssertEqual("https://new-a.example/", DurableA)
			AssertEqual("https://new-b.example/", DurableB)
			AssertEqual(DurableA, GestureActionParameters["gesture__tap_3__open_url"])
			AssertEqual(DurableB, GestureActionParameters["gesture__tap_4__open_url"],
				"Publishing A's cached clone cannot erase B's separately acknowledged live parameter")
			if Mode == "assignment" {
				AssertEqual("open_url", IniCacheGet(Parsed, "gestures", "tap_3"))
				AssertEqual("open_url", IniCacheGet(Parsed, "gestures", "tap_4"))
				AssertEqual("open_url", GestureAssignments["tap_3"])
				AssertEqual("open_url", GestureAssignments["tap_4"])
			}
		}
		AssertFalse(MenuCommandConfigBusy())
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally {
		State.Active := false
		for Callback in State.Timers
			SetTimer(Callback, 0)
		State.Timers := []
		if HadCall
			Object.Prototype.DefineProp.Call(Owner, "Call", SavedCall)
		else if Object.Prototype.HasOwnProp.Call(Owner, "Call")
			Object.Prototype.DeleteProp.Call(Owner, "Call")
		GestureAssignments := Saved.Assignments, GestureActionParameters := Saved.Parameters
		CapsWordAutoOff.Values := Saved.CapsValues, CapsWordAutoOff.Configured := Saved.CapsPolicy
		ConfigurationFile := Saved.Path
		for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache]
			if Store.Has(Fixture.path)
				Store.Delete(Fixture.path)
		_ScopeOwnerCleanup(Fixture)
		Suspend(Saved.Suspended), Critical(Saved.Critical)
	}
}
for _GCPO_Mode in ["parameter", "assignment", "capsword"]
	Test("Cached configuration candidate keeps concurrent menu publication: " . _GCPO_Mode . " (config-candidate-publication-owner)",
		_GCPO_Run.Bind(_GCPO_Mode))
