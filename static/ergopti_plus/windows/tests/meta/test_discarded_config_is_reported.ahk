; tests/meta/test_discarded_config_is_reported.ahk

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
; SCOPE: source introspection via the move-resilient helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Rejected user config is reported =======
; ===================================================
; ===================================================

_DCIR_GestureConfigValidatesAndReports() {
	Body := _DriverFuncBody("GesturesReadConfig")
	Assert(Body != "", "GesturesReadConfig() must exist")

	Assert(InStr(Body, "GESTURE_ACTIONS.Has(Value)") > 0,
		"GesturesReadConfig must validate the persisted action id against GESTURE_ACTIONS, exactly as its keyboard-shortcut sibling does — an unknown id otherwise loads verbatim and is dropped later by the dispatcher, in silence")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"a rejected gesture binding must be reported, naming the slot and the rejected id")
}

_DCIR_KeyboardShortcutFallbackIsReported() {
	Body := _DriverFuncBody("ReadKeyboardShortcutsConfig")
	Assert(Body != "", "ReadKeyboardShortcutsConfig() must exist")

	Assert(InStr(Body, "GESTURE_ACTIONS.Has(Value)") > 0,
		"prerequisite: the validity guard must still be present")
	Assert(InStr(Body, "else if") > 0 and InStr(Body, "LoggerWarn") > 0,
		"an unresolvable persisted shortcut must report the substitution — the key otherwise fires a different action than the user configured, with nothing anywhere to explain it")
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
	Assert(Body != "", "KL_AppCat_Save() must exist")

	CatchPos := InStr(Body, "catch as")
	Assert(CatchPos > 0, "the persist failure must still be caught")
	CatchBody := SubStr(Body, CatchPos)

	Assert(InStr(CatchBody, "SetTimer") > 0,
		"the I/O-failure branch must RE-ARM the deferred save — leaving dirty=true retries nothing, because the deferred save is a one-shot and its only other arm site is unreachable for an app whose key already exists")
	Assert(InStr(CatchBody, "DEFERRED_SAVE_RETRY_MS") > 0,
		"the retry must use the shared retry-window constant")
	Assert(InStr(CatchBody, "save_fn") > 0 and InStr(CatchBody, "IsObject") > 0,
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
