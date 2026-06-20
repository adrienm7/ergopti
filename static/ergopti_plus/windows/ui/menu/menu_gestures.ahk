; ui/menu/menu_gestures.ahk

; ==============================================================================
; MODULE: Tray Menu / Gestures Submenu
; DESCRIPTION:
; Builds the Gestures category submenu, its per-slot action pickers and the master gestures enable/disable toggle.
;
; Split out of ui/tray_menu.ahk (P5 refactor). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




BuildGesturesMenu() {
	global Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	DynHandlers := Map(
		"auto_configure",     (M, C) => _GES_AutoConfigure(M, C),
		"manual_tutorial",    (M, C) => _GES_ManualTutorial(M, C),
		"gesture_slots_ahk",  (M, C) => _GES_SlotsAhk(M, C),
		"gesture_slots_2",    (M, C) => _GES_Slots2(M, C),
		"gesture_slots_3",    (M, C) => _GES_Slots3(M, C),
		"gesture_slots_4",    (M, C) => _GES_Slots4(M, C),
		"gesture_slots_5",    (M, C) => _GES_Slots5(M, C),
	)
	GMenu := MenuRenderer_Build("gestures_menu", "Gestures", DynHandlers)
	; Gestures toggle uses a dedicated fn (writes Features.Enabled + Reload)
	; rather than the generic ToggleCategoryAllFeatures used by other menus.
	AddCategoryToggleItem(GMenu,
		t("menu.gestures.on"), t("menu.gestures.off"),
		GestEnabled, (*) => ToggleGesturesEnabled())
	return GMenu
}

; Dynamic handler: auto-configure button.
_GES_AutoConfigure(M, _Cat) {
	RegisterMenuItem(M, t("menu.gestures.auto_configure"), (*) => GestureAutoConfigureAction())
}

; Dynamic handler: manual tutorial button.
_GES_ManualTutorial(M, _Cat) {
	RegisterMenuItem(M, t("menu.gestures.manual_tutorial"), (*) => GestureShowManualTutorialDialog())
}

; Dynamic handler: flat slot list for AHK (mirrors pre-refactor BuildGesturesMenu).
; Iterates GESTURE_SLOTS in order, inserting a separator before tap_4 as before.
_GES_SlotsAhk(M, _Cat) {
	global GestureAssignments, GESTURE_ACTIONS, GESTURE_SLOTS, Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	for _, Slot in GESTURE_SLOTS {
		if (Slot == "tap_4")
			M.Add()
		SlotLabel     := t("gesture.slots." . Slot)
		CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
		CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction)
			? _GestureActionLabel(CurrentAction)
			: t("dialog.action_picker.disabled")
		EntryLabel := SlotLabel . " : " . CurrentLabel
		RegisterMenuItem(M, EntryLabel, ((_s, _l) => (*) => ShowActionPicker(_l,
			GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none",
			(Id) => SetGestureSlotAction(_s, Id)))(Slot, SlotLabel))
		if !GestEnabled
			M.Disable(EntryLabel)
	}
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
	GestureSaveAssignment(Slot, ActionName)
	Reload
}

; Toggles the Gestures enabled state and reloads.
ToggleGesturesEnabled() {
	global Features
	NewVal := !(Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true)
	WriteFeatureUpdate("Gestures.Enabled", NewVal)
	Reload
}





; ====================================
; =====================================
; ======= 1.X / Category toggle =======
; =====================================
; ====================================

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





; ====================================
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
; ====================================

