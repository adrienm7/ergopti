; ui/menu/menu_llm/menu_agent.ahk

; ==============================================================================
; MODULE: AI Agent Tray Submenu
; DESCRIPTION:
; The tray's top-level "AI agent" submenu (manifest agent_menu): the agent's
; mode, the backend and model of System 1 and of System 2, and the
; applications the automatic mode ignores. The fixed modes use the shared
; choice renderer; native providers supply the backend and application rows.
;
; FEATURES & RATIONALE:
; 1. The backend lists are the local server, then every provider of
;    api_providers.json in its order that can serve the system
;    (LLM_Agent_BackendChoices): a decisions provider (Jev) is listed for
;    System 1 only.
; 2. A setting is stored as "<backend>" or "<backend>|<model>", like the
;    llm_vision binding value; an empty model prompt keeps the default model.
; 3. Every change goes through the AI menu's config.toml transaction
;    (LLM_Agent_CommitSetting), then the tray is rebuilt to show it.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk





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
	return MenuRenderer_Build("agent_menu", "Agent", Map(), "", Map(
		ConfigLeaf.AGENT_SYSTEM1, () => _LLM_Agent_MenuSystemRows(ConfigLeaf.AGENT_SYSTEM1),
		ConfigLeaf.AGENT_SYSTEM2, () => _LLM_Agent_MenuSystemRows(ConfigLeaf.AGENT_SYSTEM2)),
		Map(ConfigLeaf.AGENT_MODE, _LLM_Agent_MenuSetMode, ConfigLeaf.AGENT_DISABLED_APPS, (*) => LLM_Agent_OpenAppPicker()),
		Map(ConfigKey.LLM_AGENT_MODE, () => LLM_Agent_Setting(ConfigLeaf.AGENT_MODE),
			"agent_mode_ready", () => true, "agent_disabled_apps_count", _LLM_Agent_MenuDisabledAppsCount))
}

/**
 * Supplies completed System row DATA; the declared list owns native placement.
 * @param {String} Key The actual System 1 or System 2 setting identity.
 * @returns {Array} One declared group row, or empty DATA on refused ownership.
 */
_LLM_Agent_MenuSystemRows(Key) {
	Row := _LLM_Agent_SystemRow(Key)
	return Row is Map ? [Row] : []
}






; ===========================
; ===========================
; ======= 2/ Row Data =======
; ===========================
; ===========================

/**
 * The row of System 1 or System 2: its current backend, then "Off", the local
 * server and every provider, the current one checked, then its model.
 * @param {String} Key "agent_system1" or ConfigLeaf.AGENT_SYSTEM2.
 * @returns {Map} A row with its items.
 */
_LLM_Agent_SystemRow(Key) {
	global LLM_VISION_LOCAL_BACKEND, LLM_API_PROVIDERS
	Value := LLM_Agent_Setting(Key)
	Parsed := LLM_Vision_Parse(Value)
	Current := (Parsed is Map) ? Parsed["backend"] : ""
	Off := MenuRenderer_CheckRow("agent_system_controls", MenuCommand.AGENT_SYSTEM_OFF,
		Map(MenuCommand.AGENT_SYSTEM_OFF, _LLM_Agent_MenuSetBackend.Bind(Key, "")),
		Map("agent_system_is_off", _LLM_Agent_MenuSystemIsOff.Bind(Key),
			"agent_system_off_ready", (*) => true))
	if !(Off is Map)
		return _LLM_Agent_MenuSystemFrame(Key, t("menu.agent.off"), [])
	Items := [Off]
	CurrentLabel := t("menu.agent.off")
	for Choice in LLM_Agent_BackendChoices(Key) {
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
	ModelRows := MenuRenderer_TemplateRows("agent_system_model_controls",
		Map(MenuCommand.AGENT_SYSTEM_MODEL, _LLM_Agent_MenuPromptModel.Bind(Key)),
		Map("agent_system_model_ready", (*) => Current != "",
			"agent_system_model_caption", (*) => Model), Map())
	if !(ModelRows is Array)
		return _LLM_Agent_MenuSystemFrame(Key, CurrentLabel, [])
	for Row in ModelRows
		Items.Push(Row)
	return _LLM_Agent_MenuSystemFrame(Key, CurrentLabel, Items)
}

/**
 * Receives the unchanged native backend/model children through their declared caption.
 * @param {String} Key The actual System 1 or System 2 setting identity.
 * @param {String} Caption The current native backend label, kept literal.
 * @param {Array} Items The finished native child rows, including empty refusal data.
 * @returns {Map|false} One canonical group or a refused declaration.
 */
_LLM_Agent_MenuSystemFrame(Key, Caption, Items) {
	if Key == ConfigLeaf.AGENT_SYSTEM1
		Rows := MenuRenderer_TemplateRows("agent_linux_system1_frame", Map(),
			Map("agent_system_backend_current_caption", (*) => Caption),
			Map(ConfigLeaf.AGENT_SYSTEM1, Items))
	else if Key == ConfigLeaf.AGENT_SYSTEM2
		Rows := MenuRenderer_TemplateRows("agent_linux_system2_frame", Map(),
			Map("agent_system_backend_current_caption", (*) => Caption),
			Map(ConfigLeaf.AGENT_SYSTEM2, Items))
	else
		return false
	return (Rows is Array) && Rows.Length == 1 && (Rows[1] is Map) ? Rows[1] : false
}

/**
 * Reads the current system's checked state without retaining a backend snapshot.
 * @param {String} Key The native system setting.
 * @returns {Boolean} True when no backend is selected or its value is invalid.
 */
_LLM_Agent_MenuSystemIsOff(Key) {
	Parsed := LLM_Vision_Parse(LLM_Agent_Setting(Key))
	return !(Parsed is Map) || Parsed["backend"] == ""
}

/**
 * Projects the excluded-applications command from its current main-menu authority.
 * @returns {Map|false} The declared native data row, or refused ownership.
 */
_LLM_Agent_AppsRow() {
	return MenuRenderer_CommandRow("agent_menu", ConfigLeaf.AGENT_DISABLED_APPS,
		Map(ConfigLeaf.AGENT_DISABLED_APPS, (*) => LLM_Agent_OpenAppPicker()),
		Map("agent_disabled_apps_count", _LLM_Agent_MenuDisabledAppsCount))
}

/**
 * Supplies the original apps count as native data; the shared command owns its caption.
 * @returns {String|false} The actual plain-array count, or refused native state.
 */
_LLM_Agent_MenuDisabledAppsCount() {
	Reader := LLM_Agent_Setting
	if Object.Prototype.HasOwnProp.Call(Reader, "Call")
		return false
	Apps := Reader.Call(ConfigLeaf.AGENT_DISABLED_APPS)
	if Object.Prototype.HasOwnProp.Call(Reader, "Call") || !(Apps is Array) || ObjGetBase(Apps) != Array.Prototype
		return false
	for Name in ObjOwnProps(Apps)
		return false
	return "" . Apps.Length
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
		"durable",  true,
		"title",    StrReplace(t("menu.agent.disabled_apps"), "{1}",
			LLM_Agent_Setting(ConfigLeaf.AGENT_DISABLED_APPS).Length),
		"prompt",   t("dialog.llm.exclude_prompt"),
		"ok_label", t("dialog.llm.exclude_ok"),
		"initial",  LLM_Agent_Setting(ConfigLeaf.AGENT_DISABLED_APPS),
		"on_save",  LLM_Agent_OnAppPickerSave
	))
}

; The picker's selection, stored through the AI menu's transaction.
LLM_Agent_OnAppPickerSave(Selected, Receipt) {
	global _LLM_Agent_CommitFn
	Outcome := Receipt is Map && Receipt.Get("durable_mode", false) ? AppPicker_BeginDurableSave(Receipt) : 0
	Previous := LLM_Agent_Setting(ConfigLeaf.AGENT_DISABLED_APPS)
	Mutate := _LLM_Agent_ApplyPickerSelection.Bind(Selected, Receipt)
	Apply := _LLM_Agent_ApplyCommitted.Bind(ConfigLeaf.AGENT_DISABLED_APPS, Previous)
	if HasMethod(_LLM_Agent_CommitFn, "Call") {
		; The narrow injected commit port keeps its existing three-argument ABI.
		; A false/throwing custom result has no native durability witness.
		if Outcome is Map
			Outcome["status"] := "unknown"
		Committed := _LLM_Agent_CommitFn.Call("the AI agent excluded applications", Mutate, Apply)
		if Outcome is Map && (Committed is Integer) && Committed == 1
			Outcome["status"] := "committed", Outcome["committed"] := true, Outcome["applied"] := true
	} else {
		Committed := LLM_Menu_CommitMutation("the AI agent excluded applications", Mutate, Apply,
			0, 0, 0, 0, 0, 0, 0, Outcome)
	}
	if !(Committed is Integer) || Committed != true
		return false
	LLM_Agent_RefreshTray()
	return true
}

; Candidate mutation of the picker's save: refused when another save won.
_LLM_Agent_ApplyPickerSelection(Selected, Receipt, Candidate) {
	if !(Candidate is Map) || !(Selected is Array)
		return false
	Current := Candidate.Has(ConfigLeaf.AGENT_DISABLED_APPS) ? Candidate[ConfigLeaf.AGENT_DISABLED_APPS]
		: LLM_Agent_Setting(ConfigLeaf.AGENT_DISABLED_APPS)
	if !AppPicker_ClaimReceipt(Receipt, Current)
		return false
	if !LLM_Option_TryNormalize(ConfigLeaf.AGENT_DISABLED_APPS, Selected, &Normalized)
		return false
	Candidate[ConfigLeaf.AGENT_DISABLED_APPS] := Normalized
	return true
}
