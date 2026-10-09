; ui/menu/menu_llm/menu_settings.ahk

; ==============================================================================
; MODULE: LLM Tray — Settings submenus
; DESCRIPTION:
; Builds the four settings submenus that hang off the main tray entry —
; Trigger, Generation (headed by the suggestion count), Display, Navigation —
; and the InputBox
; prompts that back every numeric / modifier / shortcut setting. Also owns
; the small set of cross-cutting helpers (``_LLM_DefaultFor``,
; ``_LLM_AssignAndRebuild``, ``_LLM_MaybeResetRow``) that every settings
; submenu uses to surface "Reset to <default>" rows.
;
; FEATURES & RATIONALE:
; 1. Reset-row hygiene: ``_LLM_MaybeResetRow`` appends a reset row ONLY when
;    the current value differs from the shared default — mirrors HS's pattern
;    of hiding the row when it would be a no-op so the menu stays compact.
; 2. Shared-defaults single source of truth: every "Reset" target reads from
;    ``LLM_Defaults`` (populated from defaults.json — the single source). The
;    loader fails fast if the file is missing, so there is no hardcoded mirror
;    map; a per-call default only covers keys the loader does not parse.
; 3. A prediction on demand is the llm_generate_prediction action
;    (LLM_Menu_TriggerPrediction), bound in a keyboard slot (Win+Space
;    recommended): the trigger submenu offers no hotkey of its own.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../../../_shared/modules/llm/trigger_policy.ahk





; ================================
; ================================
; ======= 1/ Count Choices =======
; ================================
; ================================

; Available prediction count choices (mirrors HS: for i = 1, 10 do). Declared
; beside _LLM_Menu_NRows, its only reader, so any include graph that loads the
; count rows also runs this assignment: the unit harness loads this file but
; not the menu's _index.ahk.
global LLM_MENU_N_OPTIONS := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

/**
 * Row data for the suggestion count choices (1 to 10), the submenu of the
 * first generation row (``_LLM_Menu_GenerationRows``).
 * @returns {Array} One row per option, ticked on the active one.
 */
_LLM_Menu_NRows() {
	global _LLM_Menu
	Rows := []
	for n in LLM_MENU_N_OPTIONS {
		; One key per plural form: an injected "s" is French and English only.
		CountKey := (n == 1) ? "menu.llm.prediction_count_label_one"
			: "menu.llm.prediction_count_label_other"
		Rows.Push(Map(
			"label",   StrReplace(t(CountKey), "%d", n),
			"checked", (n == _LLM_Menu["n_predictions"]),
			"action",  _LLM_Menu_MakeSetNHandler(n)))
	}
	return Rows
}





; ==================================
; ==================================
; ======= 2/ Trigger Submenu =======
; ==================================
; ==================================

/**
 * Builds the trigger settings submenu.
 * Mirrors HS: debounce (dialog), instant-on-word-end, after-hotstring,
 * URL bar filter, password field filter, and the app-exclusion picker.
 * @returns {Menu} Populated trigger submenu.
 */
LLM_Menu_BuildTriggerMenu(InstantCommand := unset, AfterCommand := unset, PrivacyCommands := 0) {
	global _LLM_Menu
	if !IsSet(InstantCommand)
		InstantCommand := LLM_Menu_OnInstantToggle
	if !IsSet(AfterCommand)
		AfterCommand := (*) => LLM_Menu_ToggleBool("after_hotstring")
	UrlSource := _LLM_Menu_PrivacySnapshot("disable_url_bars")
	SecureSource := _LLM_Menu_PrivacySnapshot("disable_password_fields")
	return MenuRenderer_Build("llm_trigger_menu", "LLM", "", "",
		Map("llm_trigger_leading", (*) => _LLM_Menu_TriggerRows("leading"),
			"llm_trigger_remaining", (*) => _LLM_Menu_TriggerRows("remaining")),
		Map("llm_instant_on_word_end", (*) => _LLM_Menu_TriggerReady() && InstantCommand.Call(),
			"llm_after_hotstring", (*) => _LLM_Menu_TriggerReady() && AfterCommand.Call(),
			"llm_url_bar_filter", (*) => _LLM_Menu_PrivacyCommand(UrlSource, "disable_url_bars",
				PrivacyCommands is Map ? PrivacyCommands.Get("disable_url_bars", 0) : 0),
			"llm_secure_field_filter", (*) => _LLM_Menu_PrivacyCommand(SecureSource, "disable_password_fields",
				PrivacyCommands is Map ? PrivacyCommands.Get("disable_password_fields", 0) : 0)),
		Map("llm_instant_on_word_end_enabled", (*) => _LLM_Menu["instant_on_word_end"],
			"llm_after_hotstring_enabled", (*) => _LLM_Menu["after_hotstring"],
			"llm_trigger_ready", _LLM_Menu_TriggerReady,
			"llm_url_bar_filter_enabled", (*) => _LLM_Menu["disable_url_bars"],
			"llm_secure_field_filter_enabled", (*) => _LLM_Menu["disable_password_fields"],
			"llm_url_bar_filter_ready", (*) => LLM_TriggerPrivacyReady(UrlSource),
			"llm_secure_field_filter_ready", (*) => LLM_TriggerPrivacyReady(SecureSource)))
}

/**
 * Reads the live trigger menu admission without coupling it to variant count.
 * @returns {Boolean} Whether a native setting command may be delivered.
 */
_LLM_Menu_TriggerReady(*) {
	global _LLM_Menu
	return _LLM_Menu["enabled"] && !A_IsSuspended
}

/** Captures actual privacy runtime and exact canonical file without publication. */
_LLM_Menu_PrivacySnapshot(Key) {
	global _LLM_Menu, _LLM_Engine, ConfigurationFile
	Snapshot := Map("owner", _LLM_Menu, "generation", LLM_AuxGeneration(),
		"backend", _LLM_Menu["backend"], "value", _LLM_Menu.Get(Key, ""),
		"enabled", _LLM_Menu["enabled"], "paused", A_IsSuspended ? true : false,
		"blocked", true, "source", 0)
	if Key != "disable_url_bars" && Key != "disable_password_fields"
		return Snapshot
	try {
		Snapshot["source"] := _LLM_Menu_EnableReadSource()
		Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		Snapshot["blocked"] := !IsSet(_LLM_Engine) || !(_LLM_Engine is Map)
			|| !_LLM_Engine.Has("enabled") || !_LLM_Engine.Has("backend") || !_LLM_Engine.Has(Key)
			|| !ManifestValuesEqual(_LLM_Engine["enabled"], Snapshot["enabled"])
			|| !(_LLM_Engine["backend"] is String)
			|| StrCompare(_LLM_Engine["backend"], Snapshot["backend"], true) != 0
			|| !ManifestValuesEqual(_LLM_Engine[Key], Snapshot["value"])
		NativeKey := Key == "disable_url_bars" ? "url_bar_filter_enabled" : "secure_filter_enabled"
		for Field, Path in Map("enabled", "llm.enabled", "backend", "llm.models.selected",
				"value", "llm.trigger." . NativeKey) {
			Read := _TOML_DocumentLookup(Document, StrSplit(Path, "."))
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Path)
			if Field != "backend" && Read["found"] && !(Value is TOML_Bool)
				Snapshot["blocked"] := true
			if Value is TOML_Bool
				Value := Value.Value
			if Read["blocked"] || (Field == "backend"
				? !(Value is String) || StrCompare(Value, Snapshot[Field], true) != 0
				: !ManifestValuesEqual(Value, Snapshot[Field]))
				Snapshot["blocked"] := true
		}
		if !_LLM_Menu_EnableSourceMatches(Snapshot["source"], _LLM_Menu_EnableReadSource())
			Snapshot["blocked"] := true
	} catch as Err {
		LoggerWarn("LLM", "Privacy row source is unavailable: {1}.", Err.Message)
		Snapshot["blocked"] := true
	}
	return Snapshot
}

/** Refuses a retained privacy checkbox before the acknowledged native setter. */
_LLM_Menu_PrivacyCommand(Expected, Key, Command := 0) {
	Current := _LLM_Menu_PrivacySnapshot(Key)
	if !_LLM_Menu_EnableSourceMatches(Expected["source"], Current["source"])
		return false
	Decision := LLM_TriggerPrivacyIntent(Expected, Current)
	if !Decision["admitted"]
		return false
	return HasMethod(Command, "Call")
		? Command.Call(Key, Decision["value"], Expected) == true
		: LLM_Menu_SetPrivacy(Key, Decision["value"], Expected) == true
}

/**
 * Row data for the trigger submenu.
 * @returns {Array} Native debounce, privacy filters and the app picker.
 */
_LLM_Menu_TriggerRows(Position := "all") {
	global _LLM_Menu
	Rows := []

	; Debounce — dialog like HS (free numeric input)
	DebounceRows := MenuRenderer_TemplateRows("llm_trigger_debounce_control",
		Map("llm_trigger_debounce", (*) => LLM_Menu_PromptDebounce()),
		Map("llm_trigger_debounce_caption", () => _LLM_Menu["debounce_ms"] . " ms"), Map())
	if !(DebounceRows is Array)
		return []
	for Row in DebounceRows
		Rows.Push(Row)
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["debounce_ms"],
		_LLM_DefaultFor("llm_debounce_ms", 500),
		(*) => _LLM_AssignAndRebuild("debounce_ms",
			_LLM_DefaultFor("llm_debounce_ms", 500)))

	BoundaryRows := MenuRenderer_TemplateRows("llm_trigger_provider_boundary", Map(), Map(), Map())
	if !(BoundaryRows is Array)
		return []
	for Row in BoundaryRows
		Rows.Push(Row)

	LeadingRows := Rows
	Rows := []

	; App exclusion picker
	n := _LLM_Menu["disabled_apps"].Length
	Rows.Push(Map(
		"label", (n > 0)
			? StrReplace(StrReplace(t("menu.llm.disabled_in_label"), "%d", n), "%s", (n > 1 ? "s" : ""))
			: t("menu.llm.exclude_from_ai"),
		"action", (*) => LLM_Menu_OpenAppPicker()))

	if Position == "leading"
		return LeadingRows
	if Position == "remaining"
		return Rows
	for Row in Rows
		LeadingRows.Push(Row)
	return LeadingRows
}





; =====================================
; =====================================
; ======= 3/ Generation Submenu =======
; =====================================
; =====================================

/**
 * Builds the generation settings submenu.
 * All numeric values use InputBox dialogs (same UX as HS settings_manager).
 * @param {Func} AutoCommand Optional acknowledged command owner for native tests.
 * @param {Func} ValuesProvider Optional unrelated numeric provider for native tests.
 * @returns {Menu} Populated generation submenu.
 */
LLM_Menu_BuildGenerationMenu(AutoCommand := unset, ValuesProvider := unset) {
	global _LLM_Menu
	if !IsSet(AutoCommand)
		AutoCommand := (*) => LLM_Menu_ToggleBool("auto_raise_temp")
	if !IsSet(ValuesProvider)
		ValuesProvider := (*) => _LLM_Menu_GenerationRows()
	return MenuRenderer_Build("llm_generation_menu", "LLM", Map(), Map(),
		Map("llm_generation_values", ValuesProvider),
		Map("llm_auto_raise_temperature", (*) => _LLM_Menu_AutoRaiseReady() ? AutoCommand.Call() : false),
		Map("llm_auto_raise_enabled", (*) => _LLM_Menu["auto_raise_temp"],
			"llm_auto_raise_ready", (*) => _LLM_Menu_AutoRaiseReady()))
}

/**
 * Reads the current prediction count before showing or delivering the check.
 * @returns {Boolean} Whether several predictions are currently requested.
 */
_LLM_Menu_AutoRaiseReady() {
	global _LLM_Menu
	return _LLM_Menu["n_predictions"] >= 2
}

/**
 * Row data for the generation submenu.
 * @returns {Array} The suggestion count, the four numeric prompts with their
 *     reset rows, plus the existing navigation reset toggle.
 */
_LLM_Menu_GenerationRows() {
	global _LLM_Menu
	Rows := []

	; Suggestion count — a generation parameter, the first one on every driver.
	CountRows := MenuRenderer_TemplateRows("llm_generation_count_control", Map(),
		Map("llm_generation_count_caption", () => "" . _LLM_Menu["n_predictions"],
			"llm_generation_ready", () => true), Map("llm_generation_count", _LLM_Menu_NRows))
	if !(CountRows is Array)
		return []
	for Row in CountRows
		Rows.Push(Row)
	; defaults.json always carries llm_num_predictions (the loader parses it), so
	; no per-call fallback shadows the shared default here.
	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["n_predictions"],
		_LLM_DefaultFor("llm_num_predictions"),
		(*) => _LLM_AssignAndRebuild("n_predictions", _LLM_DefaultFor("llm_num_predictions")))

	CountBoundaryRows := MenuRenderer_TemplateRows("llm_generation_count_boundary", Map(), Map(), Map())
	if !(CountBoundaryRows is Array)
		return []
	for Row in CountBoundaryRows
		Rows.Push(Row)

	ContextDefault := _LLM_DefaultFor("llm_context_length", 500)
	MinDefault := _LLM_DefaultFor("llm_min_words", 3)
	MaxDefault := _LLM_DefaultFor("llm_max_words", 15)
	TempDefault := Format("{:.2f}", Float(_LLM_DefaultFor("llm_temperature", "0.10")) + 0)
	max_val := _LLM_Menu["max_words"]
	max_display := (max_val == 0) ? t("menu.llm.unlimited") : max_val
	GenerationCommands := Map(
		"llm_generation_context", (*) => LLM_Menu_PromptCtxChars(),
		"llm_generation_context_reset", (*) => _LLM_AssignAndRebuild("ctx_chars", _LLM_DefaultFor("llm_context_length", 500)),
		"llm_generation_min_words", (*) => LLM_Menu_PromptMinWords(),
		"llm_generation_min_words_reset", (*) => _LLM_AssignAndRebuild("min_words", _LLM_DefaultFor("llm_min_words", 3)),
		"llm_generation_max_words", (*) => LLM_Menu_PromptMaxWords(),
		"llm_generation_max_words_reset", (*) => _LLM_AssignAndRebuild("max_words", _LLM_DefaultFor("llm_max_words", 15)),
		"llm_generation_temperature", (*) => LLM_Menu_PromptTemperature(),
		"llm_generation_temperature_reset", (*) => _LLM_AssignAndRebuild("temperature", TempDefault),
		"llm_reset_on_nav", (*) => LLM_Menu_ToggleBool("reset_on_nav"))
	GenerationGetters := Map(
		"llm_generation_ready", () => true,
		"llm_generation_context_caption", () => "" . _LLM_Menu["ctx_chars"],
		"llm_generation_context_reset_caption", () => "" . ContextDefault,
		"llm_generation_context_reset_present", () => _LLM_Menu["ctx_chars"] != ContextDefault,
		"llm_reset_on_nav_checked", () => _LLM_Menu["reset_on_nav"],
		"llm_generation_min_words_caption", () => "" . _LLM_Menu["min_words"],
		"llm_generation_min_words_reset_caption", () => "" . MinDefault,
		"llm_generation_min_words_reset_present", () => _LLM_Menu["min_words"] != MinDefault,
		"llm_generation_max_words_caption", () => "" . max_display,
		"llm_generation_max_words_reset_caption", () => "" . MaxDefault,
		"llm_generation_max_words_reset_present", () => _LLM_Menu["max_words"] != MaxDefault,
		"llm_generation_temperature_caption", () => _LLM_Menu["temperature"],
		"llm_generation_temperature_reset_caption", () => TempDefault,
		"llm_generation_temperature_reset_present", () => _LLM_Menu["temperature"] != TempDefault)
	ContextRows := MenuRenderer_TemplateRows("llm_generation_context_controls", GenerationCommands, GenerationGetters, Map())
	if !(ContextRows is Array)
		return []
	for Row in ContextRows
		Rows.Push(Row)
	ContextBoundaryRows := MenuRenderer_TemplateRows("llm_generation_context_boundary", Map(), Map(), Map())
	if !(ContextBoundaryRows is Array)
		return []
	for Row in ContextBoundaryRows
		Rows.Push(Row)
	WordRows := MenuRenderer_TemplateRows("llm_generation_word_controls", GenerationCommands, GenerationGetters, Map())
	if !(WordRows is Array)
		return []
	for Row in WordRows
		Rows.Push(Row)
	WordBoundaryRows := MenuRenderer_TemplateRows("llm_generation_words_boundary", Map(), Map(), Map())
	if !(WordBoundaryRows is Array)
		return []
	for Row in WordBoundaryRows
		Rows.Push(Row)
	TemperatureRows := MenuRenderer_TemplateRows("llm_generation_temperature_controls", GenerationCommands, GenerationGetters, Map())
	if !(TemperatureRows is Array)
		return []
	for Row in TemperatureRows
		Rows.Push(Row)

	return Rows
}





; ==================================
; ==================================
; ======= 4/ Display Submenu =======
; ==================================
; ==================================

; This initializer belongs beside the display rows so both the resident entry
; and the definitions-only native harness initialize the same catalogue.
; These are visual prefixes of the selected and alternative prediction rows;
; negative offsets never delete application text. The generated number feature
; owns the accepted range used by menu selection and runtime normalization.
global LLM_MENU_INDENT_OPTIONS := _LLMMenuBuildIndentRange()
_LLMMenuBuildIndentRange() {
	return LLM_DisplayIndentValues(ManifestFindEntryByPath("llm.display.pred_indent"))
}

/**
 * Builds the display settings submenu.
 * Mirrors HS display_menu: info bar, streaming, show-all-at-once, indent.
 * @param {Func} InfoCommand Optional acknowledged setting owner for native tests.
 * @returns {Menu} Populated display submenu.
 */
LLM_Menu_BuildDisplayMenu(InfoCommand := unset, ShowAllCommand := unset, StreamingCommand := unset, IndentCommand := unset) {
	global _LLM_Menu
	if !IsSet(InfoCommand)
		InfoCommand := LLM_Menu_SetInfoBar
	if !IsSet(ShowAllCommand)
		ShowAllCommand := (*) => LLM_Menu_ToggleBool("show_all_at_once")
	if !IsSet(StreamingCommand)
		StreamingCommand := (*) => LLM_Menu_ToggleBool("streaming")
	if !IsSet(IndentCommand)
		IndentCommand := LLM_Menu_SetIndent
	IndentSource := _LLM_Menu_IndentSnapshot()
	StreamingSource := _LLM_Menu_StreamingSnapshot()
	InfoSource := _LLM_Menu_InfoBarSnapshot()
	return MenuRenderer_Build("llm_display_menu", "LLM", Map(), Map(),
		Map("llm_display_leading", (*) => [],
			"llm_display_remaining", (*) => _LLM_Menu_DisplayRows("remaining"),
			"llm_display_trailing", (*) => _LLM_Menu_DisplayRows("trailing")),
		Map("llm_indentation", (Value) => _LLM_Menu_IndentCommand(IndentSource, Value, IndentCommand),
			"llm_info_bar", (*) => _LLM_Menu_InfoBarCommand(InfoSource, InfoCommand),
			"llm_token_streaming", (*) => _LLM_Menu_StreamingCommand(StreamingSource, StreamingCommand),
			"llm_show_all", (*) =>
			_LLM_Menu_ShowAllReady() ? ShowAllCommand.Call() : false),
		Map("llm.display.pred_indent", (*) => IndentSource["indentation"],
			"llm_indentation_ready", (*) => LLM_DisplayIndentReady(IndentSource),
			"llm_info_bar_enabled", (*) => InfoSource["info_bar"],
			"llm_info_bar_ready", (*) => LLM_DisplayInfoBarReady(InfoSource),
			"llm_show_all_enabled", (*) => _LLM_Menu["show_all_at_once"],
			"llm_show_all_ready", _LLM_Menu_ShowAllReady,
			"llm_token_streaming_enabled", (*) => LLM_EffectiveStreaming(_LLM_Menu["backend"], _LLM_Menu["streaming"]),
			"llm_token_streaming_ready", (*) => LLM_DisplayStreamingReady(StreamingSource)))
}

/** Captures the live presentation owner and its exact canonical source. */
_LLM_Menu_InfoBarSnapshot() {
	global _LLM_Menu, _LLM_Engine, ConfigurationFile
	Snapshot := Map("owner", _LLM_Menu, "generation", LLM_AuxGeneration(),
		"backend", _LLM_Menu["backend"], "info_bar", _LLM_Menu["show_info_bar"],
		"enabled", _LLM_Menu["enabled"], "paused", A_IsSuspended ? true : false,
		"source", 0, "blocked", !IsSet(_LLM_Engine) || !(_LLM_Engine is Map)
			|| !_LLM_Engine.Has("enabled") || !_LLM_Engine.Has("backend") || !_LLM_Engine.Has("show_info_bar")
			|| _LLM_Engine["enabled"] != _LLM_Menu["enabled"]
			|| _LLM_Engine["backend"] != _LLM_Menu["backend"]
			|| _LLM_Engine["show_info_bar"] != _LLM_Menu["show_info_bar"])
	try {
		Snapshot["source"] := _LLM_Menu_EnableReadSource()
		Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		for Field, Path in Map("enabled", "llm.enabled", "info_bar", "llm.display.show_info_bar",
				"backend", "llm.models.selected") {
			Read := _TOML_DocumentLookup(Document, StrSplit(Path, "."))
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Path)
			if Read["found"] && (Field == "enabled" || Field == "info_bar") && !(Value is TOML_Bool)
				Snapshot["blocked"] := true
			if Value is TOML_Bool
				Value := Value.Value
			if Read["blocked"] || !ManifestValuesEqual(Value, Snapshot[Field])
				Snapshot["blocked"] := true
		}
		if !_LLM_Menu_EnableSourceMatches(Snapshot["source"], _LLM_Menu_EnableReadSource())
			Snapshot["blocked"] := true
	} catch {
		Snapshot["blocked"] := true
	}
	return Snapshot
}

/** Refuses stale native commands before their acknowledged setting owner. */
_LLM_Menu_InfoBarCommand(Expected, Command) {
	Current := _LLM_Menu_InfoBarSnapshot()
	if !_LLM_Menu_EnableSourceMatches(Expected["source"], Current["source"])
		return false
	Decision := LLM_DisplayInfoBarIntent(Expected, Current)
	if !Decision["admitted"]
		return false
	return Command.Call(Decision["value"], Expected) == true
}

/** Captures the current menu identity, native agreement and exact file source. */
_LLM_Menu_IndentSnapshot() {
	global _LLM_Menu, _LLM_Engine, ConfigurationFile
	Snapshot := Map("owner", _LLM_Menu, "generation", LLM_AuxGeneration(),
		"backend", _LLM_Menu["backend"], "indentation", _LLM_Menu["pred_indent"],
		"progressive", LLM_DisplayProgressive(_LLM_Menu["show_all_at_once"]),
		"count", _LLM_Menu["n_predictions"], "enabled", _LLM_Menu["enabled"],
		"paused", A_IsSuspended ? true : false, "source", 0,
		"blocked", !IsSet(_LLM_Engine) || !(_LLM_Engine is Map) || !_LLM_Engine.Has("enabled") || !_LLM_Engine.Has("backend")
			|| !_LLM_Engine.Has("pred_indent") || !_LLM_Engine.Has("n_predictions")
			|| !_LLM_Engine.Has("show_all_at_once")
			|| _LLM_Engine["enabled"] != _LLM_Menu["enabled"]
			|| _LLM_Engine["backend"] != _LLM_Menu["backend"]
			|| _LLM_Engine["pred_indent"] != _LLM_Menu["pred_indent"]
			|| _LLM_Engine["n_predictions"] != _LLM_Menu["n_predictions"]
			|| _LLM_Engine["show_all_at_once"] != _LLM_Menu["show_all_at_once"])
	try {
		Snapshot["source"] := _LLM_Menu_EnableReadSource()
		Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		for Field, Path in Map("enabled", "llm.enabled", "count", "llm.profiles.num_predictions",
				"indentation", "llm.display.pred_indent", "progressive", "llm.display.streaming_multi",
				"backend", "llm.models.selected") {
			Read := _TOML_DocumentLookup(Document, StrSplit(Path, "."))
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Path)
			if Read["found"] && (Field == "enabled" || Field == "progressive") && !(Value is TOML_Bool)
				Snapshot["blocked"] := true
			if Value is TOML_Bool
				Value := Value.Value
			else if (Field == "count" || Field == "indentation") && Value is Float && Value == Integer(Value)
				Value := Integer(Value)
			if Read["blocked"] || !ManifestValuesEqual(Value, Snapshot[Field])
				Snapshot["blocked"] := true
		}
		if !_LLM_Menu_EnableSourceMatches(Snapshot["source"], _LLM_Menu_EnableReadSource())
			Snapshot["blocked"] := true
	} catch {
		Snapshot["blocked"] := true
	}
	return Snapshot
}

/** Refuses held commands before their existing acknowledged native setter. */
_LLM_Menu_IndentCommand(Expected, Value, Command) {
	Current := _LLM_Menu_IndentSnapshot()
	if !_LLM_Menu_EnableSourceMatches(Expected["source"], Current["source"])
		return false
	Decision := LLM_DisplayIndentIntent(Expected, Current, Value, LLM_MENU_INDENT_OPTIONS)
	if !Decision["admitted"]
		return false
	return Command.Call(Decision["value"], Expected) == true
}

/**
 * Captures the exact current menu/runtime owner without acquiring input.
 * @returns {Map} Native token-streaming admission snapshot.
 */
_LLM_Menu_StreamingSnapshot() {
	global _LLM_Menu, _LLM_Engine
	return Map("owner", _LLM_Menu, "generation", 0, "platform", "ahk",
		"backend", _LLM_Menu["backend"], "streaming", _LLM_Menu["streaming"],
		"progressive", LLM_DisplayProgressive(_LLM_Menu["show_all_at_once"]),
		"enabled", _LLM_Menu["enabled"], "paused", A_IsSuspended ? true : false,
		"blocked", !IsSet(_LLM_Engine) || !(_LLM_Engine is Map)
			|| !_LLM_Engine.Has("backend") || !_LLM_Engine.Has("enabled")
			|| _LLM_Engine["backend"] != _LLM_Menu["backend"]
			|| _LLM_Engine["enabled"] != _LLM_Menu["enabled"]
			|| !LLM_EffectiveStreaming(_LLM_Menu["backend"], true))
}

/**
 * Refuses an obsolete or unsupported checkbox before the canonical transaction.
 * @param {Map} Expected Exact owner captured during rendering.
 * @param {Func} Command Existing acknowledged native setting owner.
 * @returns {Integer} Boolean acknowledgement.
 */
_LLM_Menu_StreamingCommand(Expected, Command) {
	Decision := LLM_DisplayStreamingIntent(Expected, _LLM_Menu_StreamingSnapshot())
	if !Decision["admitted"]
		return false
	return Command.Call() == true
}

/**
 * Row data for the display submenu, including the nested indent picker.
 * @returns {Array} Native display settings after the shared Info Bar check.
 */
_LLM_Menu_ShowAllReady() {
	global _LLM_Menu
	return LLM_DisplayShowAllReady(_LLM_Menu["n_predictions"], !_LLM_Menu["enabled"] || A_IsSuspended ? true : false)
}

_LLM_Menu_DisplayRows(Position := "all") {
	global _LLM_Menu
	Rows := []
	n := _LLM_Menu["n_predictions"]

	; Inline auto-type — when on, the prediction is typed directly into
	; the active app instead of showing in a tooltip (Copilot-style). The
	; engine forces n=1 internally so we never race two variants. The
	; user keeps the option of bare Backspace / Ctrl+Z to roll back what
	; was typed.
	InlineRows := MenuRenderer_TemplateRows("llm_display_inline_control",
		Map("llm_display_inline", (*) => LLM_Menu_ToggleBool("inline_autotype")),
		Map("llm_display_inline_checked", () => _LLM_Menu["inline_autotype"]), Map())
	if !(InlineRows is Array)
		return []
	for Row in InlineRows
		Rows.Push(Row)

	BoundaryRows := MenuRenderer_TemplateRows("llm_display_provider_boundary", Map(), Map(), Map())
	if !(BoundaryRows is Array)
		return []
	for Row in BoundaryRows
		Rows.Push(Row)

	LeadingRows := Rows
	Rows := []

	_LLM_MaybeResetRow(Rows,
		_LLM_Menu["pred_indent"],
		_LLM_DefaultFor("llm_pred_indent", 0),
		(*) => _LLM_AssignAndRebuild("pred_indent",
			_LLM_DefaultFor("llm_pred_indent", 0)))

	if Position == "remaining"
		return LeadingRows
	if Position == "trailing"
		return Rows
	for Row in Rows
		LeadingRows.Push(Row)
	return LeadingRows
}





; =====================================
; =====================================
; ======= 5/ Navigation Submenu =======
; =====================================
; =====================================

/**
 * Builds the navigation settings submenu.
 * nav_modifiers: modifier key required to navigate predictions with arrows.
 * val_modifiers: modifier key required to select a prediction by digit.
 * Both accept free-text input (e.g. "ctrl", "alt", "" = no modifier needed).
 * @returns {Menu} Populated navigation submenu.
 */
LLM_Menu_BuildNavMenu() {
	return MenuRenderer_NewFromList("llm_menu", "llm_navigation", (*) => _LLM_Menu_NavRows())
}

/**
 * Row data for the navigation submenu.
 * Both rows are greyed below two predictions: with a single one there is
 * nothing to navigate between.
 * @returns {Array} The navigation and validation modifier rows.
 */
_LLM_Menu_NavRows() {
	global _LLM_Menu
	n := _LLM_Menu["n_predictions"]

	nav_display   := (_LLM_Menu["nav_modifiers"] != "") ? _LLM_Menu["nav_modifiers"] : t("menu.llm.arrows_only")
	val_display   := (_LLM_Menu["val_modifiers"] != "") ? _LLM_Menu["val_modifiers"] : t("menu.llm.digits_only")
	val_key_range := (n == 10) ? "1-0" : "1-" . n

	Rows := []
	for Definition in _MR_GetMenuDef("llm_navigation_rows") {
		if !(Definition is Map) || Definition.Get("type", "") != "list"
				|| !(Definition.Get("i18n", 0) is String) || Definition["i18n"] == ""
			continue
		if Definition.Get("id", "") == "llm_nav_modifiers"
			Rows.Push(Map("label", t(Definition["i18n"]) . " — " . nav_display,
				"disabled", (n < 2), "action", (*) => LLM_Menu_PromptNavModifiers()))
		else if Definition.Get("id", "") == "llm_val_modifiers"
			Rows.Push(Map("label", StrReplace(t(Definition["i18n"]), "%s", val_key_range) . " — " . val_display,
				"disabled", (n < 2), "action", (*) => LLM_Menu_PromptValModifiers()))
	}
	return Rows
}





; =============================================
; =============================================
; ======= 6/ Numeric Prompt Dispatchers =======
; =============================================
; =============================================

_LLM_Menu_NotifyInvalidInput(NotifyFn := 0) {
	Body := t("menu.llm.invalid_input")
	Title := t("common.error_title")
	if HasMethod(NotifyFn, "Call")
		NotifyFn.Call(Body, Title)
	else
		Ui_MsgBox(Body, Title, "Icon!")
	return false
}

_LLM_Menu_TryNormalizeIntegerPrompt(Result, Raw, Key, &Normalized,
		NotifyFn := 0) {
	Normalized := false
	if Result != "OK"
		return false
	if Raw == "" || !IsInteger(Raw)
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	if !LLM_Option_TryNormalize(Key, Integer(Raw), &Normalized)
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	return true
}

_LLM_Menu_TryNormalizePortPrompt(Result, Raw, &Normalized, NotifyFn := 0) {
	Normalized := false
	if Result != "OK"
		return false
	if !LLM_Option_TryNormalizeOllamaPort(Raw, &Normalized)
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	return true
}

_LLM_Menu_TryNormalizeTemperaturePrompt(Result, Raw, &Normalized,
		NotifyFn := 0) {
	Normalized := false
	if Result != "OK"
		return false
	Raw := StrReplace(Raw, ",", ".")
	if !LLM_Option_TryNormalizeTemperature(Raw, &Normalized)
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	return true
}

_LLM_Menu_TryRequiredPrompt(Result, Raw, &Normalized, NotifyFn := 0) {
	Normalized := ""
	if Result != "OK"
		return false
	Normalized := Trim(Raw)
	if Normalized == ""
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	return true
}

_LLM_Menu_TryProviderPrompt(Result, Raw, Providers, &ProviderId,
		NotifyFn := 0) {
	ProviderId := ""
	if Result != "OK"
		return false
	Candidate := Trim(Raw)
	if !(Providers is Map) || !Providers.Has(Candidate)
		return _LLM_Menu_NotifyInvalidInput(NotifyFn)
	ProviderId := Candidate
	return true
}

/**
 * Opens an InputBox for a numeric setting, validates, and applies it.
 * @param {string} key     - The _LLM_Menu key to update.
 * @param {string} title   - Dialog title.
 * @param {string} prompt  - Dialog prompt text.
 */
LLM_Menu_PromptNumeric(key, title, prompt) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptNumeric(key, title, prompt)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(prompt, title, "w400 h120", _LLM_Menu[key])
	if !_LLM_Menu_TryNormalizeIntegerPrompt(ib.Result, ib.Value, key, &val)
		return
	return LLM_Menu_CommitMutation("the LLM numeric '" . key . "' setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, key, val),
		_LLM_Menu_ApplyStandardCommitted)
}

; Resolve the shared default for ``shared_key`` (e.g. "llm_debounce_ms") from the
; runtime ``LLM_Defaults`` map (populated from defaults.json — the single source).
; The per-call ``fallback`` is a last resort only for keys the loader does not
; parse; the old hardcoded mirror map is gone. Centralised so every "Reset to N"
; row in the menu hits the same source (mirrors HS's llm_mod.DEFAULT_STATE reads).
_LLM_DefaultFor(shared_key, fallback := "") {
	global LLM_Defaults
	if IsSet(LLM_Defaults) and Type(LLM_Defaults) == "Map" and LLM_Defaults.Has(shared_key)
		return LLM_Defaults[shared_key]
	return fallback
}

; Persist a numeric / boolean tray-state change and force a menu rebuild — same
; tail every prompt setter runs. Factored out so the "Reset to N" rows can do
; the right thing without copying the boilerplate inline at every call site.
_LLM_AssignAndRebuild(tray_key, value) {
	return LLM_Menu_CommitMutation("the LLM '" . tray_key . "' reset",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, tray_key, value),
		_LLM_Menu_ApplyStandardCommitted)
}

/**
 * Appends a "Reset to <default>" row immediately below a setting when the
 * current value differs from the shared default. Mirrors HS's pattern of
 * surfacing the reset only when it would do something — a non-default value
 * means the user has customised the setting, so the reset is now useful; an
 * at-default value means the reset would be a no-op and the row is hidden to
 * keep the menu compact. The label re-uses ``menu.llm.reset_label``.
 * @param {Array} Rows        Row array to append to.
 * @param {Any}   current     Current value.
 * @param {Any}   default_val Shared default.
 * @param {Func}  on_click    Applied on click.
 */
_LLM_MaybeResetRow(Rows, current, default_val, on_click) {
	if (current = default_val)
		return
	ResetRows := MenuRenderer_TemplateRows("llm_native_numeric_reset",
		Map("llm_native_numeric_reset", on_click),
		Map("llm_numeric_reset_caption", () => "" . default_val), Map())
	if !(ResetRows is Array)
		throw Error("Declared numeric reset control was refused.")
	for Row in ResetRows
		Rows.Push(Row)
}

LLM_Menu_PromptDebounce() {
	LLM_Menu_PromptNumeric("debounce_ms", t("menu.llm.trigger_menu_title"),
		t("menu.llm.debounce_prompt"))
}

; Ollama port has its own prompt (not LLM_Menu_PromptNumeric) because applying it
; means rebuilding the HTTP client's base URL via LLM_Ollama_SetPort, not feeding
; the value through LLM_Engine_Init(LLM_Menu_BuildOpts()) — the port is a property
; of the api_ollama client, not of the engine options.
LLM_Menu_PromptOllamaPort() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptOllamaPort()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	current := _LLM_Menu.Has("ollama_port") ? _LLM_Menu["ollama_port"] : _LLM_DefaultFor("llm_ollama_port")
	ib := Ui_InputBox(t("menu.llm.ollama_port_prompt"), t("menu.llm.ollama_port_title"), "w400 h120", current)
	if !_LLM_Menu_TryNormalizePortPrompt(ib.Result, ib.Value, &val)
		return
	return LLM_Menu_CommitMutation("the Ollama port setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"ollama_port", val), _LLM_Menu_ApplyOllamaPortCommitted,
		0, 0, 0, 0, 0, _LLM_Menu_PrepareOllamaPortCandidate,
		_LLM_Menu_PublishOllamaPortCandidate)
}

; Resets the Ollama port to its shared default and applies it live.
LLM_Menu_ResetOllamaPort(default_port) {
	return LLM_Menu_CommitMutation("the Ollama port reset",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"ollama_port", default_port), _LLM_Menu_ApplyOllamaPortCommitted,
		0, 0, 0, 0, 0, _LLM_Menu_PrepareOllamaPortCandidate,
		_LLM_Menu_PublishOllamaPortCandidate)
}

_LLM_Menu_ApplyOllamaPortCommitted(Candidate) {
	if !LLM_Ollama_SetPort(Candidate["ollama_port"])
		return false
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_RequestBuild("ollama_port_committed")
	if Candidate.Get("enabled", false)
			&& Candidate.Get("backend", "") == "ollama"
		LLM_Menu_ScheduleBackendLifecycle(false)
	return true
}

LLM_Menu_PromptCtxChars() {
	LLM_Menu_PromptNumeric("ctx_chars", t("menu.llm.generation_menu_title"),
		t("menu.llm.context_length_prompt"))
}

LLM_Menu_PromptMinWords() {
	LLM_Menu_PromptNumeric("min_words", t("menu.llm.generation_menu_title"),
		t("menu.llm.min_words_prompt"))
}

LLM_Menu_PromptMaxWords() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptMaxWords()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(t("menu.llm.max_words_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Menu["max_words"])
	if !_LLM_Menu_TryNormalizeIntegerPrompt(ib.Result, ib.Value,
			"max_words", &val)
		return
	return LLM_Menu_CommitMutation("the LLM maximum-word setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"max_words", val), _LLM_Menu_ApplyStandardCommitted)
}

LLM_Menu_PromptTemperature() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptTemperature()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(t("menu.llm.temperature_prompt"), t("menu.llm.generation_menu_title"), "w400 h120", _LLM_Menu["temperature"])
	if !_LLM_Menu_TryNormalizeTemperaturePrompt(ib.Result, ib.Value,
			&Normalized)
		return
	return LLM_Menu_CommitMutation("the LLM temperature setting",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate,
			"temperature", Normalized),
		_LLM_Menu_ApplyStandardCommitted)
}

LLM_Menu_PromptNavModifiers() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptNavModifiers()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(t("menu.llm.nav_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Menu["nav_modifiers"])
	if (ib.Result != "OK")
		return
	return LLM_Menu_CommitNavModifier("nav_modifiers", ib.Value)
}

LLM_Menu_PromptValModifiers() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptValModifiers()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(t("menu.llm.val_modifiers_prompt"), t("menu.llm.nav_menu_title"), "w400 h120", _LLM_Menu["val_modifiers"])
	if (ib.Result != "OK")
		return
	return LLM_Menu_CommitNavModifier("val_modifiers", ib.Value)
}

_LLM_Menu_ApplyNavCommitted(*) {
	return _LLM_Menu_ApplyStandardCommitted()
}





; ================================================
; ================================================
; ======= 7/ Manual Prediction + Add Model =======
; ================================================
; ================================================

; The reasons a manual prediction request is refused, each with the locale key
; of the notice that tells the user. LLM_Menu_ManualPredictionRefusal decides
; which one applies; the order it checks them in is the order they are listed.
global LLM_MANUAL_PREDICTION_REFUSALS := Map(
	"paused", "llm.manual_prediction.paused",
	"disabled", "llm.manual_prediction.disabled",
	"backend_not_ready", "llm.manual_prediction.backend_not_ready",
	"empty_context", "llm.manual_prediction.empty_context",
)

/**
 * Decides why a manual prediction request cannot run, if it cannot.
 * A pause outranks everything (nothing may run while paused), then the AI
 * switch, then the backend, then the typed context.
 * @param {Boolean} IsSuspended Whether the script is paused.
 * @param {Boolean} Enabled Whether the AI is switched on.
 * @param {Boolean} BackendReady Whether the selected backend can answer.
 * @param {String} Context The context the prediction would complete.
 * @returns {String} A key of LLM_MANUAL_PREDICTION_REFUSALS, or "" when ready.
 */
LLM_Menu_ManualPredictionRefusal(IsSuspended, Enabled, BackendReady, Context) {
	if IsSuspended
		return "paused"
	if !Enabled
		return "disabled"
	if !BackendReady
		return "backend_not_ready"
	if (Context == "")
		return "empty_context"
	return ""
}

/**
 * Fires an immediate prediction request: the llm_generate_prediction action.
 * Every refusal is logged at INFO with its reason and shown as a tooltip. A
 * chord that silently does nothing reads as a broken shortcut, and the buffer
 * it completes is cleared by every caret, focus or pointer move. While paused
 * the tooltip layer paints nothing (« pause = tout éteint »), so the log line
 * is then the only trace, and a suspended hotkey cannot reach here anyway.
 * @param {Func} FireFn Receives the context; the engine when omitted.
 * @returns {Boolean} True when a prediction was requested.
 */
LLM_Menu_TriggerPrediction(FireFn := 0) {
	global _LLM_Menu, _LLM_Bridge_Buffer
	Context := SubStr(_LLM_Bridge_Buffer, -_LLM_Menu["ctx_chars"])
	Enabled := _LLM_Menu.Get("enabled", false)
	Reason := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(), Context)
	if (Reason != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Reason, StrLen(Context))
		return false
	}
	LoggerInfo("LLM", "Manual prediction requested ({1} context character(s)).", StrLen(Context))
	Fire := HasMethod(FireFn, "Call") ? FireFn : LLM_Engine_FirePrediction
	Fire(Context)
	_LLM_Menu_MarkExplicitPrediction()
	return true
}

; Marks the prediction request just fired as one the user asked for: the AI
; agent's automatic mode lets an automatic prediction tooltip be, never this one.
_LLM_Menu_MarkExplicitPrediction() {
	global _LLM_Engine
	_LLM_Engine["explicit_request_id"] := _LLM_Engine.Get("request_id", 0)
}

/**
 * Fires an immediate prediction with a prompt of its own: the
 * llm_prompt_prediction action and the llm_predict_<profile> presets. It is
 * llm_generate_prediction with the named profile and count for this request
 * only: the active profile, the per-app overrides and the menu's count are
 * left untouched. The same refusals are logged and shown; a prompt that no
 * longer exists (a deleted custom prompt) is refused with its own notice and is
 * never replaced by another one.
 * @param {String} ProfileId The profile to run, built-in or custom.
 * @param {Integer} NumPredictions The binding's own count, 0 for the menu's.
 * @param {Func} FireFn Receives the context and the override Map; the engine
 *     when omitted.
 * @returns {Boolean} True when a prediction was requested.
 */
LLM_Menu_TriggerPredictionWith(ProfileId, NumPredictions := 0, FireFn := 0, TranslationTarget := "") {
	global _LLM_Menu, _LLM_Bridge_Buffer
	Profile := (TranslationTarget != "") ? ((ProfileId == "translate")
		? LLM_Translate_PredictionProfile(TranslationTarget) : 0)
		: LLM_FindProfile(ProfileId, _LLM_Menu["user_profiles"])
	; A rewrite rewrites the current sentence, whatever its length: the engine
	; receives the whole buffer and extends its capped context to the sentence.
	; Its "nothing typed" is an empty sentence, not an empty buffer.
	IsRewrite := LLM_Rewrite_IsRewriteProfile(Profile)
	Context := IsRewrite ? _LLM_Bridge_Buffer
		: SubStr(_LLM_Bridge_Buffer, -_LLM_Menu["ctx_chars"])
	Enabled := _LLM_Menu.Get("enabled", false)
	Reason := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(),
		IsRewrite ? LLM_Rewrite_SentenceSpan(Context) : Context)
	if (Reason != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Reason, StrLen(Context))
		return false
	}
	if !(Profile is Map) {
		LoggerWarn("LLM", "Prompt prediction refused: the prompt '{1}' no longer exists.", ProfileId)
		_LLM_Menu_ShowManualPredictionNotice("llm.prompt_prediction.unknown_prompt")
		return false
	}
	LoggerInfo("LLM", "Prompt prediction requested with '{1}' ({2} prediction(s), {3} context character(s)).",
		ProfileId, (NumPredictions > 0) ? NumPredictions : _LLM_Menu["n_predictions"], StrLen(Context))
	Override := Map("profile_id", ProfileId, "num_predictions", NumPredictions)
	if (TranslationTarget != "")
		Override["translation_target"] := TranslationTarget
	if HasMethod(FireFn, "Call") {
		FireFn(Context, Override)
		_LLM_Menu_MarkExplicitPrediction()
		return true
	}
	; A debounce armed by the last keystroke would otherwise fire right after
	; and supersede this request with the active profile.
	LLM_Engine_CancelTimer()
	LLM_Engine_FirePrediction(Context, , Override)
	_LLM_Menu_MarkExplicitPrediction()
	return true
}

/**
 * Runs the llm_live_prompt_toggle action: turns live mode on with the prompt
 * and count of the binding, or off when it is on, whichever binding turned it
 * on.
 * @param {String} ProfileId The prompt to run, built-in or custom.
 * @param {Integer} NumPredictions The binding's own count, 0 for the menu's.
 * @returns {Boolean} True when live mode changed state.
 */
LLM_Menu_ToggleLiveMode(ProfileId, NumPredictions := 0, TranslationTarget := "") {
	if LLM_Engine_LiveIsActive()
		return LLM_Menu_StopLiveMode()
	return LLM_Menu_StartLiveMode(ProfileId, NumPredictions, TranslationTarget)
}

/**
 * Turns live mode on with a prompt of its own, or moves it to that prompt.
 * The menu's active profile and settings are left untouched. The refusals of
 * a manual prediction apply, but for the empty context: live mode waits for
 * the user to type. A prompt that no longer exists is refused with its notice
 * and never replaced by another one.
 * @param {String} ProfileId The prompt to run, built-in or custom.
 * @param {Integer} NumPredictions The binding's own count, 0 for the menu's.
 * @returns {Boolean} True when live mode is on with that prompt.
 */
LLM_Menu_StartLiveMode(ProfileId, NumPredictions := 0, TranslationTarget := "") {
	global _LLM_Menu, _LLM_Bridge_Buffer
	Enabled := _LLM_Menu.Get("enabled", false)
	Reason := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(), _LLM_Bridge_Buffer)
	if (Reason != "" && Reason != "empty_context") {
		_LLM_Menu_ShowManualPredictionRefusal(Reason, StrLen(_LLM_Bridge_Buffer))
		return false
	}
	Profile := (TranslationTarget != "") ? ((ProfileId == "translate")
		? LLM_Translate_PredictionProfile(TranslationTarget) : 0)
		: LLM_FindProfile(ProfileId, _LLM_Menu["user_profiles"])
	if !(Profile is Map) {
		LoggerWarn("LLM", "Live mode refused: the prompt '{1}' no longer exists.", ProfileId)
		_LLM_Menu_ShowManualPredictionNotice("llm.prompt_prediction.unknown_prompt")
		return false
	}
	LLM_Engine_LiveStart(ProfileId, NumPredictions, TranslationTarget)
	_LLM_Menu_ShowNotice(StrReplace(t("llm.live.on"), "{1}", (TranslationTarget != "") ? Profile["label"] : LLM_Menu_GetProfileLabel(ProfileId)))
	LLM_Menu_RequestBuild("live_mode")
	return true
}

/**
 * Turns live mode off and dismisses its tooltip; the menu's "Off" row.
 * @returns {Boolean} True when live mode was on.
 */
LLM_Menu_StopLiveMode() {
	if !LLM_Engine_LiveStop("turned off by the user")
		return false
	if LLM_Tooltip_IsVisible()
		LLM_Tooltip_Hide()
	_LLM_Menu_ShowNotice(t("llm.live.off"))
	LLM_Menu_RequestBuild("live_mode")
	return true
}

; Logs a manual-request refusal at INFO with its reason and shows its notice.
; @param {String} Reason A key of LLM_MANUAL_PREDICTION_REFUSALS.
; @param {Integer} ContextLength Characters of context the request had.
_LLM_Menu_ShowManualPredictionRefusal(Reason, ContextLength) {
	global _LLM_Menu, LLM_MANUAL_PREDICTION_REFUSALS
	LoggerInfo("LLM", "Manual prediction refused ({1}): backend '{2}', {3} context character(s).",
		Reason, _LLM_Menu.Get("backend", ""), ContextLength)
	_LLM_Menu_ShowManualPredictionNotice(LLM_MANUAL_PREDICTION_REFUSALS[Reason])
}

; Shows a manual-request notice the way every refusal is shown.
; @param {String} Key The locale key of the notice.
_LLM_Menu_ShowManualPredictionNotice(Key) {
	_LLM_Menu_ShowNotice(t(Key))
}

; Shows an AI notice the way every manual-request refusal is shown.
; @param {String} Text The translated notice.
_LLM_Menu_ShowNotice(Text) {
	TooltipShow({ Text: Text, DurationSec: UI_HOTSTRING_TIMEOUT_SEC },
		UI_HOTSTRING_TIMEOUT_SEC)
}

/**
 * Prompts the user to enter a custom Ollama model identifier.
 */
LLM_Menu_PromptAddModel() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptAddModel()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	ib := Ui_InputBox(t("menu.llm.ollama_model_hint"), t("menu.llm.add_custom_model"), "w450 h130")
	if (ib.Result != "OK" || Trim(ib.Value) == "")
		return
	name := Trim(ib.Value)
	LLM_Menu_SetModel(name)
}
