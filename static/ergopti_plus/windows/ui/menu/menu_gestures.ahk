; ui/menu/menu_gestures.ahk

; ==============================================================================
; MODULE: Tray Menu / Gestures Submenu
; DESCRIPTION:
; Builds the Gestures category submenu, its per-slot action pickers and the master gestures enable/disable toggle.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================

#Include ../gesture_conflicts.ahk



BuildGesturesMenu() {
	DynHandlers := Map(
		"gesture_slots_2",    (M, C) => _GES_Slots2(M, C),
		"gesture_slots_3",    (M, C) => _GES_Slots3(M, C),
		"gesture_slots_4",    (M, C) => _GES_Slots4(M, C),
		"gesture_slots_5",    (M, C) => _GES_Slots5(M, C),
	)
	; The two whole-tree actions are `command` rows since 2026-08-07: the renderer
	; builds each row and its label from the declaration, and this driver
	; registers only what the click does. All three drivers had been writing the
	; same two rows with the same two labels.
	; The two whole-tree actions joined them on the same day, and the two buttons
	; below on 2026-08-07: each handler's whole body was one row with a static
	; label, which the declaration already expresses.
	; The category switch is the manifest's `gestures_toggle` row. Its command is
	; the dedicated writer (gestures.enabled + reload) rather than the generic
	; CategoryEnabled flip the master-gated menus register.
	Commands := Map(
		"gestures_toggle",  (*) => ToggleGesturesEnabled(),
		"system_gesture_settings", (*) => GestureOpenTouchpadSettings(),
		"disable_all",      (*) => _GES_SetEverySlot("none"),
		"restore_defaults", (*) => _GES_RestoreFactoryDefaults(),
		"auto_configure",   (*) => GestureAutoConfigureAction(),
		"manual_tutorial",  (*) => GestureShowManualTutorialDialog(),
	)
	Getters := Map("gestures_enabled", _GES_IsEnabled)
	ListProviders := Map("gesture_slots_ahk", (*) => _GES_SlotRows(),
		"system_gesture_status", (*) => GestureSystemRows())
	return MenuRenderer_Build("gestures_menu", "Gestures", DynHandlers, "", ListProviders, Commands, Getters)
}

; True when the gestures feature is switched on in the loaded configuration.
_GES_IsEnabled() {
	global Features
	return Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
}


; Whole-scope actions use the manifest owner, including the master and parameters.
_GES_SetEverySlot(ActionName) {
	if ActionName != "none"
		throw ValueError("The clear command cannot assign an arbitrary action.")
	return _GES_ApplyScope("clear")
}

_GES_RestoreFactoryDefaults() {
	return _GES_ApplyScope("recommended")
}

; The receipt remains pending until the existing terminal reload acknowledges it.
_GES_ApplyScope(Mode, Options := unset) {
	return ConfigScopeApply("gestures", Mode,
		Map("action_parameters", ConfigScopeActionParameterPaths), IsSet(Options) ? Options : Map())
}

; List provider: flat slot list for AHK (mirrors pre-refactor BuildGesturesMenu).
; Iterates GESTURE_SLOTS in order, inserting a separator before tap_4 as before.
; Row DATA since 2026-08-07, as on Linux: each label is the slot plus the action
; currently bound to it, which no static declaration can carry.
_GES_SlotRows() {
	global GestureAssignments, GESTURE_ACTIONS, GESTURE_SLOTS, Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	Rows := []
	for _, Slot in GESTURE_SLOTS {
		if (Slot == "tap_4")
			Rows.Push(Map("separator", true))
		SlotLabel     := t("gesture.slots." . Slot)
		CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
		CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction)
			? GestureActionDisplayLabel(CurrentAction, GestureBindingId("gesture", Slot))
			: t("dialog.action_picker.disabled")
		Rows.Push(Map(
			"label",    SlotLabel . " : " . CurrentLabel,
			"disabled", !GestEnabled,
			"action",   ((_s, _l) => (*) => ShowActionPicker(_l,
				GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none",
				(Id) => SetGestureSlotAction(_s, Id), false, GestureBindingId("gesture", _s)))(Slot, SlotLabel)))
	}
	return Rows
}

; Dynamic handlers for HS finger groups (unused on AHK — manifest filters them out).
_GES_Slots2(M, _Cat) {
	return
}
_GES_Slots3(M, _Cat) {
	return
}
_GES_Slots4(M, _Cat) {
	return
}
_GES_Slots5(M, _Cat) {
	return
}

; Applies a new action to a gesture slot and reloads.
SetGestureSlotAction(Slot, ActionName) {
	global GestureAssignments
	if !GestureAssignConfiguredAction(&GestureAssignments,
			"gesture", "gestures", Slot, ActionName)
		return false
	if ActionName == "none"
		return ReloadPreservingSuspend()
	return GestureSystemAfterAssignment(Slot)
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
	global Features
	NewVal := !_GES_IsEnabled()
	; v2-native write via the canonical manifest path — no v1->v2 translation.
	; WriteFeatureV2 derives the [gestures] section + the Features node from
	; the path and persists in lock-step (see infra/feature_io.ahk).
	if !WriteFeatureV2(Features, "gestures.enabled", NewVal)
		return ConfigReportPersistenceFailure("the gestures enable toggle")
	return ReloadPreservingSuspend()
}





; ==================================
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
; ==================================
