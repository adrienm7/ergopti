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
		MenuCommand.GESTURE_RECOMMENDED_INFO, (*) => GestureShowRecommendedInfo(),
	)
	Getters := Map("gestures_enabled", _GES_IsEnabled)
	; There is no status provider: the slot rows below carry the availability
	; themselves, and « Infos… » explains it in a dialog.
	ListProviders := Map("gesture_slots_ahk", (*) => _GES_SlotRows())
	Built := MenuRenderer_Build("gestures_menu", "Gestures", DynHandlers, "", ListProviders, Commands, Getters)
	if Built is Menu
		GestureSystemWatchMenu(Built)
	return Built
}

/**
 * Shows why a gesture is offered or greyed out, behind the menu's « Infos… » row.
 * The text is several sentences long, and AutoHotkey refuses a menu item name
 * over 260 UTF-16 units. On Windows the driver takes the system's own
 * assignment over itself, so the shared "remove the system assignment first"
 * note does not apply and only the Windows reason is shown.
 * @returns {String} The native button the user pressed.
 */
GestureShowRecommendedInfo() {
	return Ui_MsgBox(t("menu.gestures.recommended_reason_windows"), t("menu.gestures.notify_title"), "Iconi")
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
; A slot the system does not map to Ergopti's shortcut is greyed out and its
; label ends with the reason; the availability is re-read at every build.
; @param ReadFn {Func|0} Injectable registry reader (tests); the real one when omitted.
_GES_SlotRows(ReadFn := 0) {
	global GestureAssignments, GESTURE_ACTIONS, GESTURE_SLOTS, Features
	GestureSystemRefresh(ReadFn)
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
		Reason := GestureSystemUnavailableReason(Slot)
		Rows.Push(Map(
			"label",    SlotLabel . " : " . CurrentLabel . (Reason != "" ? " — " . Reason : ""),
			"disabled", !GestEnabled || Reason != "",
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
	return ReloadPreservingSuspend()
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
	NotifyFeature(t("menu.gestures.notify_title"), NewVal)
	return ReloadPreservingSuspend()
}





; ==================================
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
; ==================================
