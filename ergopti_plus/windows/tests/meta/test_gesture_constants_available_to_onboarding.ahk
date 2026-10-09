; tests/meta/test_gesture_constants_available_to_onboarding.ahk

; ==============================================================================
; MODULE: Gesture Constants Reachable From Onboarding (gesture-manual-tutorial-empty)
; DESCRIPTION:
; On a first run the wizard's « Enregistrer manuellement » button opened a panel
; that ended with "puis taper le raccourci indiqué :" and then listed nothing.
; All ten "3 doigts vers le haut :  Ctrl + Win + Shift + F2" rows were missing,
; so the user could not perform the setup the panel had just described. The same
; dialog opened from the tray menu after the wizard rendered correctly, which is
; why it never showed up in a maintainer log.
;
; ROOT CAUSE ENCODED: #Include executes a file's top-level statements at the
; include POSITION. GESTURE_SLOTS and GESTURE_SHORTCUT_LABELS were top-level
; assignments in modules/gestures/init.ahk, included ~300 lines AFTER
; ErgoptiPlus.ahk calls the blocking Onboarding_Run(). Both were therefore
; declared-but-unassigned for the whole wizard, and an IsSet() guard around the
; row loop turned that load-order bug into a silently empty list instead of a
; loud failure. Function definitions have no include position — the whole script
; is parsed before any statement runs — so the data now lives behind accessors.
;
; SCOPE: source introspection for the load-order property (the harness includes
; gestures/init.ahk, so its globals ARE set there and a behavioural test alone
; would pass with or without the fix), plus a behavioural check that the
; accessors really carry all ten rows.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================================
; =====================================================================
; ======= 1/ The load-order hazard still exists =======================
; =====================================================================
; =====================================================================

; If the wizard ever moved after the gestures include, the guard below would be
; protecting against nothing. Assert the premise rather than assume it.
_GCAO_WizardStillRunsBeforeTheGesturesModule() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	Code := _StripFullLineComments(Src)

	WizardPos := InStr(Code, "Onboarding_Run()")
	IncludePos := InStr(Code, "#Include modules/gestures/init.ahk")
	Assert(WizardPos > 0 and IncludePos > 0,
		"both Onboarding_Run() and the gestures module include must still exist in the entry point")
	Assert(WizardPos < IncludePos,
		"premise: Onboarding_Run() still runs BEFORE the gestures module's top-level statements, so anything the wizard calls must not depend on those statements having run")
}
Test("gestures: the wizard still runs before the gestures module's top-level code (gesture-manual-tutorial-empty)",
	_GCAO_WizardStillRunsBeforeTheGesturesModule)




; =====================================================================
; =====================================================================
; ======= 2/ The tutorial builder is order-independent ================
; =====================================================================
; =====================================================================

_GCAO_BuilderUsesAccessorsNotTopLevelGlobals() {
	Body := _DriverFuncBody("GestureBuildSetupInstructions")
	Assert(Body != "", "GestureBuildSetupInstructions must exist in modules/gestures/config.ahk")

	Assert(InStr(Body, "GestureSlotIds(") > 0,
		"GestureBuildSetupInstructions must read the slot ids through the GestureSlotIds() accessor — a function has no include position, so it answers correctly during the first-run wizard")
	Assert(InStr(Body, "GestureShortcutLabels(") > 0,
		"GestureBuildSetupInstructions must read the shortcut labels through the GestureShortcutLabels() accessor for the same reason")
	Assert(InStr(Body, "GESTURE_SLOTS") = 0 and InStr(Body, "GESTURE_SHORTCUT_LABELS") = 0,
		"GestureBuildSetupInstructions must not read the GESTURE_SLOTS / GESTURE_SHORTCUT_LABELS globals: they are top-level assignments that have not executed yet when the wizard calls this function, so the tutorial renders with no shortcut rows at all (gesture-manual-tutorial-empty)")
	Assert(InStr(Body, "IsSet(") = 0,
		"GestureBuildSetupInstructions must not guard on IsSet(): the guard is what converted a load-order bug into an empty tutorial instead of a loud failure")
}
Test("gestures: the manual-setup tutorial reads order-independent accessors (gesture-manual-tutorial-empty)",
	_GCAO_BuilderUsesAccessorsNotTopLevelGlobals)


; The accessors themselves must stay pure data. A t() call inside one would put
; them back behind I18nPreload and reintroduce the ordering dependency by the
; back door — which is exactly why GESTURE_SLOT_LABELS stays in init.ahk.
_GCAO_AccessorsAreLocaleFree() {
	for _, Name in ["GestureSlotIds", "GestureShortcutLabels"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in modules/gestures/constants.ahk")
		Assert(InStr(Body, "static") > 0,
			Name . "() must memoise its data in a static so repeated calls stay free")
		Assert(InStr(Body, " t(") = 0 and InStr(Body, "=t(") = 0,
			Name . "() must not call t(): a locale lookup would make it depend on I18nPreload having run, reintroducing the load-order hazard this accessor exists to remove")
	}
}
Test("gestures: the constant accessors stay locale-free (gesture-manual-tutorial-empty)",
	_GCAO_AccessorsAreLocaleFree)




; =====================================================================
; =====================================================================
; ======= 3/ All ten rows really are emitted ==========================
; =====================================================================
; =====================================================================

_GCAO_AllTenSlotRowsPresent() {
	Slots := GestureSlotIds()
	Labels := GestureShortcutLabels()
	Assert(Slots.Length = 10,
		"all ten gesture slots must be listed — the tutorial is the only place the user learns which shortcut to bind")
	for _, Slot in Slots {
		Assert(Labels.Has(Slot),
			"slot '" . Slot . "' has no shortcut label, so its tutorial row would render with an empty shortcut")
	}

	Body := GestureBuildSetupInstructions()
	Assert(InStr(Body, "Ctrl + Win + Shift + F1") > 0,
		"the built tutorial must contain the first slot's shortcut")
	Assert(InStr(Body, "Ctrl + Win + Shift + F10") > 0,
		"the built tutorial must contain the last slot's shortcut — a body that stops at the header is the exact symptom this regression encodes")
}
Test("gestures: the manual-setup tutorial lists all ten shortcut rows (gesture-manual-tutorial-empty)",
	_GCAO_AllTenSlotRowsPresent)
