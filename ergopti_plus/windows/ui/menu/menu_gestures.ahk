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



/**
 * Builds the Gestures submenu from the manifest's gestures_menu array.
 * @param {Map} Options Scope owner options, injected by the scope tests only;
 *     the tray passes none, so its rows act on the real configuration.
 * @returns {Menu} The rendered submenu.
 */
BuildGesturesMenu(Options := unset) {
	ScopeOptions := IsSet(Options) ? Options : Map()
	DynHandlers := Map(
		"gesture_slots_2",    (M, C) => _GES_Slots2(M, C),
		"gesture_slots_3",    (M, C) => _GES_Slots3(M, C),
		"gesture_slots_4",    (M, C) => _GES_Slots4(M, C),
		"gesture_slots_5",    (M, C) => _GES_Slots5(M, C),
	)
	; The scope's restore and clear are `command` rows of the first group since
	; 2026-09-30 (switch, restore, clear, separator): the renderer builds each row
	; and its label from the declaration, and this driver registers only what the
	; click does. The two buttons below became `command` rows on 2026-08-07: each
	; handler's whole body was one row with a static label.
	; The category switch is the manifest's `gestures_toggle` row. Its command is
	; the dedicated writer (gestures.enabled + reload) rather than the generic
	; CategoryEnabled flip the master-gated menus register.
	Commands := Map(
		"gestures_toggle",  (*) => ToggleGesturesEnabled(),
		"system_gesture_settings", (*) => GestureOpenTouchpadSettings(),
		"scope_restore",    (*) => _GES_ApplyScope("recommended", ScopeOptions),
		"scope_clear",      (*) => _GES_ApplyScope("clear", ScopeOptions),
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
; The receipt remains pending until the existing terminal reload acknowledges it.
_GES_ApplyScope(Mode, Options := unset) {
	Selected := IsSet(Options) ? Options.Clone() : Map()
	if !(Selected is Map) || Selected.Has("supplement")
		throw ValueError("Gesture scope requires its own persistence supplement.")
	Selected["supplement"] := GestureScopeResetOperations
	return ConfigScopeApply("gestures", Mode,
		Map("action_parameters", ConfigScopeActionParameterPaths), Selected)
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
		if (Slot == "tap_4") {
			Boundary := MenuRenderer_StatusRows("gestures_menu", "gesture_slots_ahk", "tap_group_boundary")
			if !(Boundary is Array)
				return []
			for Row in Boundary
				Rows.Push(Row)
		}
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
