; ui/menu/menu_llm/menu_agent.ahk

; ==============================================================================
; MODULE: AI Agent Tray Submenu
; DESCRIPTION:
; The tray's top-level "AI agent" submenu (manifest agent_menu): the agent's
; mode, the backend and model of System 1 and of System 2, and the
; applications the automatic mode ignores. Every row is a manifest `dynamic`
; slot whose rows are handed to the renderer as data.
;
; FEATURES & RATIONALE:
; 1. The backend lists are the screen reading's: the local server, then every
;    provider of api_providers.json in its order (LLM_Vision_BackendChoices).
; 2. A setting is stored as "<backend>" or "<backend>|<model>", like the
;    llm_vision binding value; an empty model prompt keeps the default model.
; 3. Every change goes through the AI menu's config.toml transaction
;    (LLM_Agent_CommitSetting), then the tray is rebuilt to show it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Submenu =======
; ==========================
; ==========================

/**
 * Builds the agent submenu from the manifest.
 * @returns {Object} The submenu the tray's "agent" row opens.
 */
LLM_Agent_MenuBuild() {
	return MenuRenderer_Build("agent_menu", "Agent", Map(
		"agent_mode", _LLM_Agent_MenuModeSlot,
		"agent_system1", _LLM_Agent_MenuSystemSlot.Bind("agent_system1"),
		"agent_system2", _LLM_Agent_MenuSystemSlot.Bind("agent_system2"),
		"agent_disabled_apps", _LLM_Agent_MenuAppsSlot))
}

; Dynamic slot agent_mode: its row and the three modes.
_LLM_Agent_MenuModeSlot(Target, CategoryName) {
	MenuRenderer_AppendRows(Target, "agent_menu", "agent_mode", [_LLM_Agent_ModeRow()])
}

; Dynamic slot agent_system1 or agent_system2: its row and its backends.
_LLM_Agent_MenuSystemSlot(Key, Target, CategoryName) {
	MenuRenderer_AppendRows(Target, "agent_menu", Key, [_LLM_Agent_SystemRow(Key)])
}

; Dynamic slot agent_disabled_apps: the application picker.
_LLM_Agent_MenuAppsSlot(Target, CategoryName) {
	MenuRenderer_AppendRows(Target, "agent_menu", "agent_disabled_apps", [_LLM_Agent_AppsRow()])
}





; ===========================
; ===========================
; ======= 2/ Row Data =======
; ===========================
; ===========================

/**
 * The mode row: "Mode: <current>", then off, on action and automatic, the
 * current one checked.
 * @returns {Map} A row with its items.
 */
_LLM_Agent_ModeRow() {
	global LLM_AGENT_MODES
	Current := LLM_Agent_Setting("agent_mode")
	Items := []
	for Mode in LLM_AGENT_MODES
		Items.Push(Map(
			"label", t("menu.agent.mode_" . Mode),
			"checked", Mode == Current,
			"action", _LLM_Agent_MenuSetMode.Bind(Mode)))
	return Map(
		"label", StrReplace(t("menu.agent.mode_title"), "{1}", t("menu.agent.mode_" . Current)),
		"items", Items)
}

/**
 * The row of System 1 or System 2: its current backend, then "Off", the local
 * server and every provider, the current one checked, then its model.
 * @param {String} Key "agent_system1" or "agent_system2".
 * @returns {Map} A row with its items.
 */
_LLM_Agent_SystemRow(Key) {
	global LLM_VISION_LOCAL_BACKEND, LLM_API_PROVIDERS
	Value := LLM_Agent_Setting(Key)
	Parsed := LLM_Vision_Parse(Value)
	Current := (Parsed is Map) ? Parsed["backend"] : ""
	Items := [Map(
		"label", t("menu.agent.off"),
		"checked", Current == "",
		"action", _LLM_Agent_MenuSetBackend.Bind(Key, ""))]
	CurrentLabel := t("menu.agent.off")
	for Choice in LLM_Vision_BackendChoices() {
		Label := (Choice["value"] == LLM_VISION_LOCAL_BACKEND)
			? Choice["value"] . " — " . Choice["label"] : Choice["label"]
		if (Choice["value"] == Current)
			CurrentLabel := Choice["label"]
		Items.Push(Map(
			"label", Label,
			"checked", Choice["value"] == Current,
			"action", _LLM_Agent_MenuSetBackend.Bind(Key, Choice["value"])))
	}
	Model := LLM_Agent_ResolveModel(Parsed, LLM_Agent_Config(), LLM_API_PROVIDERS)
	Items.Push(Map("separator", true))
	Items.Push(Map(
		"label", StrReplace(t("menu.agent.model"), "{1}", Model),
		"disabled", Current == "",
		"action", _LLM_Agent_MenuPromptModel.Bind(Key)))
	return Map("label", StrReplace(t("menu.agent." . SubStr(Key, 7)), "{1}", CurrentLabel), "items", Items)
}

/**
 * The excluded applications row, with their count.
 * @returns {Map}
 */
_LLM_Agent_AppsRow() {
	return Map(
		"label", StrReplace(t("menu.agent.disabled_apps"), "{1}", LLM_Agent_Setting("agent_disabled_apps").Length),
		"action", (*) => LLM_Agent_OpenAppPicker())
}





; ===========================
; ===========================
; ======= 3/ Handlers =======
; ===========================
; ===========================

; A mode row: the mode, refused for "auto" without both systems.
_LLM_Agent_MenuSetMode(Mode, *) {
	return LLM_Agent_SetMode(Mode)
}

; A backend row: the backend, keeping the model only when it stays the same
; backend. Choosing the backend that is already chosen changes nothing.
_LLM_Agent_MenuSetBackend(Key, Backend, *) {
	Parsed := LLM_Vision_Parse(LLM_Agent_Setting(Key))
	Current := (Parsed is Map) ? Parsed["backend"] : ""
	if (Backend == Current)
		return false
	if !LLM_Agent_CommitSetting(Key, Backend)
		return false
	LoggerInfo("LLM", "AI agent {1} set to '{2}'.", Key, Backend == "" ? "off" : Backend)
	return true
}

; The model row: a native prompt, empty for the backend's default model.
_LLM_Agent_MenuPromptModel(Key, *) {
	global _LLM_Agent_PromptFn
	Parsed := LLM_Vision_Parse(LLM_Agent_Setting(Key))
	if !(Parsed is Map)
		return false
	Prompt := HasMethod(_LLM_Agent_PromptFn, "Call") ? _LLM_Agent_PromptFn : _LLM_Agent_NativePrompt
	Answer := Prompt.Call(t("menu.agent.title"),
		StrReplace(t("dialog.agent.model_prompt"), "{1}", LLM_Agent_BackendLabel(Parsed["backend"])),
		Parsed.Get("model", ""))
	if !Answer["ok"]
		return false
	Model := Trim(Answer["value"])
	Value := (Model == "") ? Parsed["backend"] : Parsed["backend"] . "|" . Model
	if !LLM_Vision_IsValid(Value) {
		LoggerWarn("LLM", "AI agent {1}: the model name was refused.", Key)
		_LLM_Menu_ShowManualPredictionNotice("dialog.gestures.param_err_llm_vision")
		return false
	}
	if (Value == LLM_Agent_Setting(Key))
		return false
	return LLM_Agent_CommitSetting(Key, Value)
}

/**
 * Opens the shared application picker for the applications the automatic
 * mode ignores.
 */
LLM_Agent_OpenAppPicker() {
	AppPicker_Show(Map(
		"owner",    "agent:disabled_apps",
		"title",    StrReplace(t("menu.agent.disabled_apps"), "{1}",
			LLM_Agent_Setting("agent_disabled_apps").Length),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  LLM_Agent_Setting("agent_disabled_apps"),
		"on_save",  LLM_Agent_OnAppPickerSave
	))
}

; The picker's selection, stored through the AI menu's transaction.
LLM_Agent_OnAppPickerSave(Selected, Receipt) {
	global _LLM_Agent_CommitFn
	Commit := HasMethod(_LLM_Agent_CommitFn, "Call") ? _LLM_Agent_CommitFn : LLM_Menu_CommitMutation
	if !Commit.Call("the AI agent excluded applications",
			_LLM_Agent_ApplyPickerSelection.Bind(Selected, Receipt),
			_LLM_Agent_ApplyCommitted.Bind("agent_disabled_apps"))
		return false
	LLM_Agent_RefreshTray()
	return true
}

; Candidate mutation of the picker's save: refused when another save won.
_LLM_Agent_ApplyPickerSelection(Selected, Receipt, Candidate) {
	if !(Candidate is Map) || !(Selected is Array)
		return false
	Current := Candidate.Has("agent_disabled_apps") ? Candidate["agent_disabled_apps"]
		: LLM_Agent_Setting("agent_disabled_apps")
	if !AppPicker_ClaimReceipt(Receipt, Current)
		return false
	if !LLM_Option_TryNormalize("agent_disabled_apps", Selected, &Normalized)
		return false
	Candidate["agent_disabled_apps"] := Normalized
	return true
}
