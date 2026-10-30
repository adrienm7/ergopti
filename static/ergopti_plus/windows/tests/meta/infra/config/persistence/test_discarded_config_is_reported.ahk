; tests/meta/infra/config/persistence/test_discarded_config_is_reported.ahk

; ==============================================================================
; MODULE: Discarded Configuration Reporting Meta Test
; DESCRIPTION:
; Four places where the driver threw away something the user had configured, or
; something a manifest declared, without saying so. Falling back is usually the
; right BEHAVIOUR; the silence is the defect, because the observable result is a
; control that does the wrong thing with no explanation available anywhere.
;
;   Gestures had no validity guard at all, unlike its keyboard-shortcut sibling.
;   A slot bound to an action id that no longer exists loaded verbatim and was
;   dispatched, where GestureInvokeAction's own guard dropped it — so the
;   gesture fired, produced nothing, and logged nothing. Indistinguishable from
;   the gesture not being recognised.
;
;   Keyboard shortcuts HAD the guard but no else, so an unresolvable assignment
;   was replaced by the shipped default in silence: the key fires a DIFFERENT
;   action than the user configured.
;
;   MenuRenderer_Build dropped action/dynamic items whose handler id was missing
;   while every sibling branch — including the unknown-item-type fallback right
;   below it — logged. Manifest/handler drift simply removed menu entries.
;
;   KL_AppCat_Save's catch left a comment promising a retry that nothing armed.
;   The deferred save is a ONE-SHOT, and its only other arm site registers the
;   app key BEFORE arming, so that path is unreachable for the same app once the
;   key exists. A transient lock lost the discovery permanently.
;
; SCOPE: the two readers run for real on a persisted section; the menu and retry
; paths are still read from source through the move-resilient helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Rejected user config is reported =======
; ===================================================
; ===================================================

; Runs the reader on a persisted section and returns the lines it logged.
_DCIR_LinesWhileReading(Reader, Section, Stored) {
	global _IniCache
	SavedCache := _IniCache
	Lines := []
	try {
		_IniCache := Map(Section, Stored)
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Reader.Call()
	} finally {
		LoggerClearTestSink()
		_IniCache := SavedCache
	}
	return Lines
}

_DCIR_Reported(Lines, Needle) {
	for Line in Lines {
		if InStr(Line, "[WARNING]") && InStr(Line, Needle)
			return true
	}
	return false
}

_DCIR_GestureConfigValidatesAndReports() {
	global GestureAssignments, GestureActionParameters, GESTURE_ACTIONS
	SavedAssignments := IsSet(GestureAssignments) ? GestureAssignments : unset
	SavedParameters := IsSet(GestureActionParameters) ? GestureActionParameters : unset
	try {
		GestureAssignments := Map("tap_3", "shipped_default", "tap_4", "shipped_default")
		Known := ""
		for ActionId, _ in GESTURE_ACTIONS {
			Known := ActionId
			break
		}
		Assert(Known != "", "the catalogue must offer a known action")
		Lines := _DCIR_LinesWhileReading(GesturesReadConfig, "gestures",
			Map("tap_3", "retired_action_id", "tap_4", Known))
		AssertEqual("shipped_default", GestureAssignments["tap_3"],
			"an unknown id must not load verbatim: the dispatcher would drop it later, in silence")
		AssertEqual(Known, GestureAssignments["tap_4"], "a known id still loads")
		AssertTrue(_DCIR_Reported(Lines, "retired_action_id"),
			"a rejected gesture binding must be reported, naming the rejected id")
	} finally {
		GestureAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
		GestureActionParameters := IsSet(SavedParameters) ? SavedParameters : unset
	}
}

_DCIR_KeyboardShortcutFallbackIsReported() {
	global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS
	SavedAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	try {
		KEYBOARD_SHORTCUT_DEFAULTS := Map("win_d", "shipped_default")
		KeyboardShortcutAssignments := Map()
		Lines := _DCIR_LinesWhileReading(ReadKeyboardShortcutsConfig, "shortcuts.keyboard",
			Map("win_d", "retired_action_id"))
		AssertEqual("shipped_default", KeyboardShortcutAssignments["win_d"],
			"an unresolvable shortcut falls back to the shipped default")
		AssertTrue(_DCIR_Reported(Lines, "retired_action_id"),
			"the substitution must be reported: the key otherwise fires a different action than the user configured, with nothing anywhere to explain it")
	} finally {
		KeyboardShortcutAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedDefaults) ? SavedDefaults : unset
	}
}

; Both id-keyed manifest branches must report a missing handler. Checking only
; one is how the pair diverged in the first place.
_DCIR_MenuDropsAreReported() {
	Body := _DriverFuncBody("MenuRenderer_Build")
	Assert(Body != "", "MenuRenderer_Build() must exist")

	for Kind in ["action", "dynamic"] {
		Marker := "No handler for " . Kind . " item"
		Assert(InStr(Body, Marker) > 0,
			"MenuRenderer_Build must report a dropped '" . Kind . "' item — manifest/handler drift otherwise removes menu entries silently, while the unknown-item-type branch beside it has always logged")
	}
}




; ===============================================
; ===============================================
; ======= 2/ A promised retry is real ===========
; ===============================================
; ===============================================

_DCIR_AppCategorySaveActuallyRetries() {
	Body := _DriverFuncBody("KL_AppCat_Save")
	ScheduleBody := _DriverFuncBody("_KL_AppCat_ScheduleDeferredSave")
	Assert(Body != "" and ScheduleBody != "",
		"the category save and retry owner must exist")

	CatchPos := InStr(Body, "catch as")
	Assert(CatchPos > 0, "the persist failure must still be caught")
	CatchBody := SubStr(Body, CatchPos)

	Assert(InStr(CatchBody, "_KL_AppCat_ScheduleDeferredSave()") > 0,
		"the I/O-failure branch must RE-ARM the deferred save — leaving dirty=true retries nothing, because the deferred save is a one-shot and its only other arm site is unreachable for an app whose key already exists")
	Assert(InStr(ScheduleBody, "SetTimer") > 0
		and InStr(ScheduleBody, "DEFERRED_SAVE_RETRY_MS") > 0,
		"the retry must use the shared retry-window constant")
	Assert(InStr(ScheduleBody, "save_fn") > 0
		and InStr(ScheduleBody, "IsObject") > 0,
		"the re-arm must be guarded on save_fn being bound — KL_AppCat_Reload can reach this before the timer callback has ever been registered")
}


Test("meta config: a rejected gesture binding is validated and reported",
	_DCIR_GestureConfigValidatesAndReports)
Test("meta config: an unresolvable keyboard shortcut reports its fallback",
	_DCIR_KeyboardShortcutFallbackIsReported)
Test("meta config: dropped manifest menu items are reported",
	_DCIR_MenuDropsAreReported)
Test("meta config: the app-category save retry is armed, not just promised",
	_DCIR_AppCategorySaveActuallyRetries)
