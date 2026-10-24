; modules/keymap/pause_layout_switch.ahk

; ==============================================================================
; MODULE: Pause Layout Switch (Windows)
; DESCRIPTION:
; Switches the keyboard layout when the driver pauses, resumes or quits, to
; the layouts chosen in Layout > « Layout on pause / resume », and builds those
; rows from the shared manifest frames macOS and Linux draw too.
;
; FEATURES & RATIONALE:
; 1. One policy. PauseSwitchPolicyTarget (the AHK twin of the Lua policy)
;    decides the layout of each event from Features["layout"]; this file only
;    reads the settings and calls the native switch.
; 2. Lifecycle owner. Ergopti_OnSuspendEnter, Ergopti_OnSuspendResume and the
;    terminal quit run PauseLayoutSwitch_Apply through _LifecycleRunRequiredStep
;    as owner "keyboard-layout": 1 is a switch made or nothing to switch, false
;    a refused switch, which the transition reports as its debt.
; 3. The picker lists the layouts installed for the user (KLS_Choices) after
;    « No change »; a choice is written through WriteFeatureV2.
; ==============================================================================

#Requires AutoHotkey v2.0




/**
 * The three settings as the policy reads them.
 * @param {Map} FeaturesMap The loaded Features.
 * @returns {Map} Keys "enabled", "on_pause", "on_resume".
 */
PauseLayoutSwitch_Settings(FeaturesMap) {
	global PAUSE_SWITCH_POLICY_PATHS
	if !(FeaturesMap is Map) || !FeaturesMap.Has("layout") || !(FeaturesMap["layout"] is Map)
		throw Error("the layout settings are not loaded")
	Layout := FeaturesMap["layout"]
	Settings := Map()
	for Role, Path in PAUSE_SWITCH_POLICY_PATHS {
		Key := SubStr(Path, InStr(Path, ".") + 1)
		Settings[Role] := Layout.Has(Key) ? Layout[Key] : ManifestDefaultFor(Path)
	}
	return Settings
}

/**
 * Switches to the layout one event selects.
 * @param {String} Event "pause", "resume" or "quit".
 * @param {Func} SelectFn Optional switch port with KLS_Select's contract.
 * @returns {Integer|Boolean} 1 when the layout was requested or nothing
 *   switches, false when the switch was refused.
 */
PauseLayoutSwitch_Apply(Event, SelectFn := 0) {
	global Features
	if !IsSet(Features)
		throw Error("the layout settings are not loaded")
	Target := PauseSwitchPolicyTarget(PauseLayoutSwitch_Settings(Features), Event)
	if (Target == "")
		return 1
	if !HasMethod(SelectFn, "Call")
		SelectFn := KLS_Select
	try LoggerInfo("PauseLayoutSwitch", "Switching the keyboard layout to {1} on {2}.", Target, Event)
	Result := SelectFn.Call(Target)
	if !((Result is Integer) && Result == 1) {
		try LoggerError("PauseLayoutSwitch", "Keyboard layout not switched to {1} on {2}.", Target, Event)
		return false
	}
	return 1
}

/**
 * Whether an OnExit reason is the user's own quit: the tray Exit item ("Menu")
 * or the quit action ("Exit", from ExitApp). A reload, a logoff, a shutdown or
 * another instance taking over leaves the layout as it is, as on macOS and Linux.
 * @param {String} Reason The OnExit reason.
 * @returns {Boolean}
 */
PauseLayoutSwitch_IsUserQuit(Reason) {
	return StrCompare(Reason, "Menu", true) == 0 || StrCompare(Reason, "Exit", true) == 0
}

/**
 * Persists one setting and redraws the tray.
 * @param {String} Path One of PAUSE_SWITCH_POLICY_PATHS.
 * @param {Any} Value A value the setting can hold.
 * @param {Func} WriterFn Optional WriteFeatureV2 seam.
 * @param {Func} RebuildFn Optional tray rebuild seam.
 * @returns {Integer|Boolean} 1 once written and redrawn, otherwise false.
 */
PauseLayoutSwitch_Set(Path, Value, WriterFn := 0, RebuildFn := 0) {
	global Features
	if !HasMethod(WriterFn, "Call")
		WriterFn := WriteFeatureV2
	if !HasMethod(RebuildFn, "Call")
		RebuildFn := RebuildTrayMenu
	Written := WriterFn.Call(Features, Path, Value)
	if !((Written is Integer) && Written == 1) {
		try LoggerError("PauseLayoutSwitch", "Setting {1} was not saved.", Path)
		return false
	}
	RebuildFn.Call()
	return 1
}

/**
 * The rows of Layout > « Layout on pause / resume », from the shared frames.
 * @param {Func} ChoicesFn Optional installed-layout port with KLS_Choices' contract.
 * @param {Func} SetFn Optional persistence seam with PauseLayoutSwitch_Set's contract.
 * @returns {Array} Provider rows, empty when a frame is refused.
 */
PauseLayoutSwitch_MenuRows(ChoicesFn := 0, SetFn := 0) {
	global Features, PAUSE_SWITCH_POLICY_PATHS
	if !HasMethod(ChoicesFn, "Call")
		ChoicesFn := KLS_Choices
	if !HasMethod(SetFn, "Call")
		SetFn := PauseLayoutSwitch_Set
	Settings := PauseLayoutSwitch_Settings(Features)
	Choices := ChoicesFn.Call()
	Enabled := (Settings["enabled"] is Integer) && Settings["enabled"] == 1
	LabelFor(Value) {
		Id := PauseSwitchPolicyTargetId(Value)
		if (Id == "")
			return t("menu.layout.layout_auto")
		for Choice in Choices
			if (Choice["id"] == Id)
				return Choice["label"]
		return Id
	}
	; The renderer runs a Func action, never a BoundFunc, and a closure over the
	; loop variable would see its last value: one call per choice owns its id.
	PickAction(Path, ChosenId) {
		return (*) => SetFn.Call(Path, ChosenId)
	}
	Picker(Role) {
		Path := PAUSE_SWITCH_POLICY_PATHS[Role]
		Current := PauseSwitchPolicyTargetId(Settings[Role])
		Native := []
		for Choice in Choices
			Native.Push(Map("label", Choice["label"], "checked", Current == Choice["id"],
				"action", PickAction(Path, Choice["id"])))
		; Own names: a nested function assigning an outer variable shares it.
		PickerRows := MenuRenderer_TemplateRows("layout_switch_picker_frame",
			Map("layout_picker_auto", (*) => SetFn.Call(Path, "")),
			Map("layout_picker_auto_checked", () => Current == "",
				"layout_picker_has_choices", () => Native.Length > 0),
			Map("layout_picker_choices", (*) => Native))
		return PickerRows is Array ? PickerRows : []
	}
	Rows := MenuRenderer_TemplateRows("layout_switching_frame",
		Map("layout_switch_toggle", (*) => SetFn.Call(PAUSE_SWITCH_POLICY_PATHS["enabled"], !Enabled)),
		Map("layout_switch_checked", () => Enabled,
			"layout_switch_ready", () => Enabled && !A_IsSuspended,
			"layout_pause_caption", () => LabelFor(Settings["on_pause"]),
			"layout_resume_caption", () => LabelFor(Settings["on_resume"])),
		Map("layout_pause_picker", (*) => Picker("on_pause"),
			"layout_resume_picker", (*) => Picker("on_resume")))
	return Rows is Array ? Rows : []
}
