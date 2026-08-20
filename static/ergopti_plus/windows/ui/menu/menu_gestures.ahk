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




BuildGesturesMenu() {
	global Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
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
	Commands := Map(
		"disable_all",      (*) => _GES_SetEverySlot("none"),
		"restore_defaults", (*) => _GES_RestoreFactoryDefaults(),
		"auto_configure",   (*) => GestureAutoConfigureAction(),
		"manual_tutorial",  (*) => GestureShowManualTutorialDialog(),
	)
	ListProviders := Map("gesture_slots_ahk", (*) => _GES_SlotRows())
	GMenu := MenuRenderer_Build("gestures_menu", "Gestures", DynHandlers, "", ListProviders, Commands)
	; Gestures toggle uses a dedicated fn (writes Features.Enabled + Reload)
	; rather than the generic ToggleCategoryAllFeatures used by other menus.
	AddCategoryToggleItem(GMenu,
		t("menu.gestures.on"), t("menu.gestures.off"),
		GestEnabled, (*) => ToggleGesturesEnabled())
	return GMenu
}


; These actions alter bindings only. They deliberately keep the master gesture
; toggle intact, so an existing user choice to keep gestures off is respected.
_GES_SetEverySlot(ActionName) {
	global GESTURE_SLOTS
	Assignments := Map()
	for _, Slot in GESTURE_SLOTS
		Assignments[Slot] := ActionName
	if !GestureSaveAllAssignments(Assignments)
		return false
	return ReloadPreservingSuspend()
}

_GES_RestoreFactoryDefaults() {
	global GESTURE_SLOTS, GESTURE_FACTORY_DEFAULTS
	Assignments := Map()
	for _, Slot in GESTURE_SLOTS
		Assignments[Slot] := GESTURE_FACTORY_DEFAULTS.Has(Slot) ? GESTURE_FACTORY_DEFAULTS[Slot] : "none"
	if !GestureSaveAllAssignments(Assignments)
		return false
	return ReloadPreservingSuspend()
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
				(Id) => SetGestureSlotAction(_s, Id)))(Slot, SlotLabel)))
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
	return ReloadPreservingSuspend()
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
	global Features
	NewVal := !(Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true)
	; v2-native write via the canonical manifest path — no v1->v2 translation.
	; WriteFeatureV2 derives the [gestures] section + the Features node from
	; the path and persists in lock-step (see infra/feature_io.ahk).
	if !WriteFeatureV2(Features, "gestures.enabled", NewVal)
		return ConfigReportPersistenceFailure("the gestures enable toggle")
	return ReloadPreservingSuspend()
}





; =====================================
; =====================================
; ======= 1.X / Category toggle =======
; =====================================
; =====================================

; Insert the canonical « ✅ X activé(s) (cliquer pour désactiver) » /
; « ❌ X désactivé(s) (cliquer pour activer) » synthetic top item into a
; submenu, followed by a separator at position 2. AHK does not let us
; bind a callback on the parent label of a submenu (clicks open the
; submenu), so this is how every category exposes its global on/off
; toggle in a uniform way — same pattern Métriques uses.
;
; ``on_label`` and ``off_label`` are passed in full (not built from a
; template) so each category keeps its own French gender/number
; agreement: « activée » for « Disposition », « activés » for
; « Raccourcis », « activées » for « Métriques », etc.
AddCategoryToggleItem(menu, on_label, off_label, is_enabled, on_click) {
	label := is_enabled ? on_label : off_label
	; Insert via the bypass helper so the category-level toggle gets the
	; same WM_COMMAND retry coverage as the individual feature toggles
	; below. Without this, clicks on the "Activer / Désactiver" row at
	; the top of every submenu are still subject to AHK's native dispatch
	; drop pattern.
	RegisterMenuItemInsert(menu, "1&", label, on_click)
	menu.Insert("2&")  ; separator
}





; ==================================
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
; ==================================
