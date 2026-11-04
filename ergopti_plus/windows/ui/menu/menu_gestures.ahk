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
#Include %A_LineFile%\..\..\..\_generated\config_keys.ahk



/**
 * Builds the Gestures submenu from the manifest's gestures_menu array.
 * @param {Map} Options Scope owner options, injected by the scope tests only;
 *     the tray passes none, so its rows act on the real configuration.
 * @returns {Menu} The rendered submenu.
 */
BuildGesturesMenu(Options := unset) {
	; The tray's clear restores the real touchpad; injected options carry a fake.
	ScopeOptions := IsSet(Options) ? Options : Map("touchpad_restore", TouchpadRegistryRestore)
	; The scope's restore and clear are `command` rows of the first group since
	; 2026-09-30 (switch, restore, clear, separator): the renderer builds each row
	; and its label from the declaration, and this driver registers only what the
	; click does. The two buttons below became `command` rows on 2026-08-07: each
	; handler's whole body was one row with a static label.
	Commands := _GES_MenuCommands(ScopeOptions)
	Getters := Map("gestures_enabled", _GES_IsEnabled)
	; There is no status provider: the slot rows below carry the availability
	; themselves, and « Infos… » explains it in a dialog.
	ListProviders := Map("gesture_slots_ahk", (*) => _GES_SlotRows())
	Built := MenuRenderer_Build("gestures_menu", "Gestures", Map(), "", ListProviders, Commands, Getters)
	if Built is Menu
		GestureSystemWatchMenu(Built)
	return Built
}

/**
 * What each Gestures row does when clicked.
 * The category switch is the manifest's `gestures_toggle` row. Its command is
 * the dedicated writer (gestures.enabled + reload) rather than the generic
 * CategoryEnabled flip the master-gated menus register.
 * « Infos… » only opens a message box, so it is a startup UI command: a click
 * right after a (re)load opens it at once instead of waiting about five
 * seconds for input initialization like a command that changes state.
 * @param {Map} ScopeOptions Options of the scope restore and clear.
 * @returns {Map} Command id => callback.
 */
_GES_MenuCommands(ScopeOptions) {
	return Map(
		MenuCommand.GESTURES_TOGGLE, (*) => ToggleGesturesEnabled(),
		MenuCommand.SCOPE_RESTORE, (*) => _GES_ApplyScope("recommended", ScopeOptions),
		MenuCommand.SCOPE_CLEAR, (*) => _GES_ApplyScope("clear", ScopeOptions),
		MenuCommand.AUTO_CONFIGURE, (*) => GestureAutoConfigureAction(),
		MenuCommand.MANUAL_TUTORIAL, (*) => GestureShowManualTutorialDialog(),
		MenuCommand.GESTURE_RECOMMENDED_INFO,
			MenuStartupUiCommand((*) => GestureShowRecommendedInfo(), MenuStartupDiagnosticsReady),
	)
}

/**
 * Shows why a gesture is offered or greyed out, behind the menu's « Infos… » row.
 * It reads no registry and rebuilds nothing: the text is static, so the click
 * path stays a single message box.
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
; The clear also puts the touchpad back to its system state (the registry
; backup, or the Windows factory defaults): « comportement du système » means
; Windows' own gestures again, not only an empty Ergopti configuration. It runs
; first because its touchpad restart asks for elevation, which must not hold
; up the reload handoff the configuration commit starts.
_GES_ApplyScope(Mode, Options := unset) {
	Selected := IsSet(Options) ? Options.Clone() : Map()
	if !(Selected is Map) || Selected.Has("supplement")
		throw ValueError("Gesture scope requires its own persistence supplement.")
	Touchpad := Mode == "clear" ? TouchpadRegistryClearFromScope(Selected) : ""
	Selected["supplement"] := GestureScopeResetOperations
	Receipt := ConfigScopeApply("gestures", Mode,
		Map("action_parameters", ConfigScopeActionParameterPaths), Selected)
	if (Touchpad != "")
		Receipt["touchpad"] := Touchpad
	return Receipt
}

; List provider: the slots grouped by finger count, fewest fingers first, in
; GESTURE_SLOTS order within a group. Each group opens with its declared header
; (status row fingers_N) and two groups are parted by finger_group_boundary, so
; the headers are the ones macOS declares per group.
; Row DATA since 2026-08-07, as on Linux: each label is the slot plus the action
; currently bound to it, which no static declaration can carry.
; A slot the system does not map to Ergopti's shortcut is greyed out and its
; label ends with the reason; the availability is re-read at every build.
; @param ReadFn {Func|0} Injectable registry reader (tests); the real one when omitted.
_GES_SlotRows(ReadFn := 0) {
	global GESTURE_SLOTS
	GestureSystemRefresh(ReadFn)
	Groups := Map()
	for _, Slot in GESTURE_SLOTS {
		if !RegExMatch(Slot, "^[a-z]+_(\d+)", &Fingers)
			throw ValueError("Gesture slot without a finger count: " . Slot)
		Count := Integer(Fingers[1])
		if !Groups.Has(Count)
			Groups[Count] := []
		Groups[Count].Push(Slot)
	}
	; Spelled out, not built from the count, so the manifest reader gate sees
	; each declared header read.
	HeaderStatus := Map(3, "fingers_3", 4, "fingers_4")
	; A Map enumerates integer keys in ascending order.
	Rows := []
	for Count, Slots in Groups {
		if Rows.Length > 0 && !_GES_PushStatusRows(Rows, "finger_group_boundary")
			return []
		if !HeaderStatus.Has(Count) || !_GES_PushStatusRows(Rows, HeaderStatus[Count])
			return []
		for Slot in Slots
			Rows.Push(_GES_SlotRow(Slot))
	}
	return Rows
}

; Appends one declared status template of the slot list; false when it is
; missing or refused, so the caller publishes no partial list.
_GES_PushStatusRows(Rows, Status) {
	Declared := MenuRenderer_StatusRows("gestures_menu", "gesture_slots_ahk", Status)
	if !(Declared is Array)
		return false
	for Row in Declared
		Rows.Push(Row)
	return true
}

; One slot row: the slot, the action bound to it, and its availability.
_GES_SlotRow(Slot) {
	global GestureAssignments, GESTURE_ACTIONS, Features
	GestEnabled := Features.Has("gestures") and Features["gestures"].Has("enabled")
		and Features["gestures"]["enabled"] = true
	SlotLabel     := t("gesture.slots." . Slot)
	CurrentAction := GestureAssignments.Has(Slot) ? GestureAssignments[Slot] : "none"
	CurrentLabel  := GESTURE_ACTIONS.Has(CurrentAction)
		? GestureActionDisplayLabel(CurrentAction, GestureBindingId("gesture", Slot))
		: t("dialog.action_picker.disabled")
	Reason := GestureSystemUnavailableReason(Slot)
	return Map(
		"label",    LabelValue(SlotLabel, CurrentLabel) . (Reason != "" ? " — " . Reason : ""),
		"disabled", !GestEnabled || Reason != "",
		"action",   ((_s, _l) => (*) => ShowActionPicker(_l,
			GestureAssignments.Has(_s) ? GestureAssignments[_s] : "none",
			(Id) => SetGestureSlotAction(_s, Id), false, GestureBindingId("gesture", _s)))(Slot, SlotLabel))
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
	if !WriteFeatureV2(Features, ConfigKey.GESTURES_ENABLED, NewVal)
		return ConfigReportPersistenceFailure("the gestures enable toggle")
	NotifyFeature(t("menu.gestures.notify_title"), NewVal)
	return ReloadPreservingSuspend()
}





; ==================================
; ==================================
; ======= 1.X / Metrics menu =======
; ==================================
; ==================================
