; modules/llm/translate.ahk

; ==============================================================================
; MODULE: Selection Translation (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/translate.lua: the pure logic behind the
; llm_translate_selection action, which translates the selected text with the
; AI menu's current text backend and offers it in the prediction tooltip.
;
; FEATURES & RATIONALE:
; 1. The binding names the target language: "ui" (the interface language,
;    followed when the user changes it) or a locale code of
;    _shared/data/locale_names.json. Only shipped locales are accepted, so the
;    picker and the native prompt offer a closed list and a typo is refused.
; 2. The prompt names the language by its native name ("Deutsch", "日本語"),
;    which models understand, so no second table of names is kept.
; 3. Prompt, tag and token budget live in _shared/modules/llm/translate.json,
;    read once and validated whole, like vision.json.
; 4. The answer is read like the screen answers: the text after the tag, over
;    any number of lines, without bold markers (LLM_Vision_Extract).
;
; Pinned with the Lua module by _shared/tests/corpus/llm/translate_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Binding Parameter =======
; ====================================
; ====================================

/**
 * Parses a binding value.
 * @param {String} Value The stored parameter.
 * @param {Map} Config The decoded translate.json.
 * @param {Map} Names The decoded locale_names.json.
 * @returns {String} Admitted language value; "" when invalid.
 */
LLM_Translate_Parse(Value, Config, Names) {
	if !LLM_Translate_IsLanguageText(Value) || StrPut(Value, "UTF-8") - 1 > Config["max_language_bytes"]
		return ""
	return Value
}

/**
 * Validates the Unicode and reserved-character syntax independent of runtime limits.
 * @param {String} Value Stored target token or language name.
 * @returns {Integer} True for syntactically valid language text.
 */
LLM_Translate_IsLanguageText(Value) {
	if !(Value is String) || Value == "" || Value != Trim(Value, " `t`r`n`v`f")
		return false
	if RegExMatch(Value, "[|{}\x00-\x1f\x7f-\x9f]")
		return false
	Offset := 1
	while (Offset <= StrLen(Value)) {
		ScalarUnit := Ord(SubStr(Value, Offset, 1))
		if (ScalarUnit >= 0xD800 && ScalarUnit <= 0xDBFF) {
			if (Offset == StrLen(Value))
				return false
			Following := Ord(SubStr(Value, Offset + 1, 1))
			if (Following < 0xDC00 || Following > 0xDFFF)
				return false
			Offset += 1
		} else if (ScalarUnit >= 0xDC00 && ScalarUnit <= 0xDFFF)
			return false
		Offset += 1
	}
	return true
}

/**
 * Tells whether a binding value is valid against the shipped files.
 * @param {String} Value The stored parameter.
 * @returns {Boolean}
 */
LLM_Translate_IsValid(Value) {
	Target := LLM_Translate_Parse(Value, LLM_Translate_Config(), LLM_Translate_LocaleNames())
	return (Target != "") ? true : false
}

/**
 * Returns the locale code a parsed target resolves to.
 * @param {String} Target A value LLM_Translate_Parse accepted.
 * @param {Map} Config The decoded translate.json.
 * @param {String} UiLocale The interface locale code.
 * @returns {String}
 */
LLM_Translate_TargetLocale(Target, Config, UiLocale) {
	return (Target == Config["ui_value"]) ? UiLocale : Target
}

/**
 * Returns the native name the prompt uses for a locale.
 * @param {String} Code A shipped locale code.
 * @param {Map} Names The decoded locale_names.json.
 * @returns {String} The name, "" for an unknown code.
 */
LLM_Translate_LanguageName(Code, Names) {
	Locales := (Names is Map) ? Names.Get("locales", "") : ""
	if !(Code is String) || !(Locales is Map) || !Locales.Has(Code) || !(Locales[Code] is Map)
		return ""
	Name := Locales[Code].Get("name", "")
	return (Name is String) ? Name : ""
}

/**
 * Returns the choices a binding may take, in display order: the interface
 * language first, then every shipped locale.
 * @param {Map} Names The decoded locale_names.json.
 * @param {Map} Order The decoded locale_order.json.
 * @param {Map} Config The decoded translate.json.
 * @param {String} UiLabel Localized label of the interface-language choice.
 * @returns {Array} Maps ("value", "label").
 */
LLM_Translate_Choices(Names, Order, Config, UiLabel) {
	Choices := [Map("value", Config["ui_value"], "label", UiLabel)]
	for Code in Order["order"] {
		Entry := Names["locales"][Code]
		Choices.Push(Map("value", Code, "label", Entry["flag"] . " " . Entry["name"]))
	}
	return Choices
}





; ==============================
; ==============================
; ======= 2/ The Request =======
; ==============================
; ==============================

/**
 * Returns the system prompt for a target language. The name is inserted
 * literally: StrReplace reads no pattern in it.
 * @param {Map} Config The decoded translate.json.
 * @param {String} Language Native name of the target language.
 * @returns {String}
 */
LLM_Translate_SystemPrompt(Config, Language) {
	return StrReplace(Config["prompt"], "{language}", Language)
}

/**
 * Returns the user turn carrying the selection.
 * @param {Map} Config The decoded translate.json.
 * @param {String} Text The selected text.
 * @returns {String}
 */
LLM_Translate_UserText(Config, Text) {
	return Config["user_prefix"] . Text
}

/**
 * Extracts the translation from a raw model answer.
 * @param {Map} Config The decoded translate.json.
 * @param {String} Block The raw model answer.
 * @returns {String} The translation, "" when the tag is missing or nothing follows it.
 */
LLM_Translate_Extract(Config, Block) {
	return LLM_Vision_Extract(Block, Config["tag"])
}





; =======================================
; =======================================
; ======= 3/ Shared Configuration =======
; =======================================
; =======================================

/**
 * Returns the decoded, validated translate.json, read on first use.
 * @returns {Map}
 */
LLM_Translate_Config() {
	global _SharedDir
	static Config := ""
	if (Config is Map)
		return Config
	Path := _SharedDir . "\modules\llm\translate.json"
	Candidate := JsonParse(FSReadStrict(Path))
	_LLM_Translate_ValidateConfig(Candidate, Path)
	Config := Candidate
	return Config
}

/**
 * Returns the decoded, validated locale_names.json, read on first use.
 * @returns {Map}
 */
LLM_Translate_LocaleNames() {
	global _SharedDir
	static Names := ""
	if (Names is Map)
		return Names
	Path := _SharedDir . "\data\locale_names.json"
	Candidate := JsonParse(FSReadStrict(Path))
	Locales := (Candidate is Map) ? Candidate.Get("locales", "") : ""
	if !(Locales is Map) || Locales.Count == 0
		throw ValueError(Path . ": locales must be a non-empty object.")
	for Code, Entry in Locales {
		if !(Entry is Map) || !(Entry.Get("name", "") is String) || Entry["name"] == ""
				|| !(Entry.Get("flag", "") is String)
			throw ValueError(Path . ": the locale '" . Code . "' needs a name and a flag.")
	}
	Names := Candidate
	return Names
}

/**
 * Returns the decoded, validated locale_order.json, read on first use.
 * @returns {Map}
 */
LLM_Translate_LocaleOrder() {
	global _SharedDir
	static Order := ""
	if (Order is Map)
		return Order
	Path := _SharedDir . "\data\locale_order.json"
	Candidate := JsonParse(FSReadStrict(Path))
	Codes := (Candidate is Map) ? Candidate.Get("order", "") : ""
	if !(Codes is Array) || Codes.Length == 0
		throw ValueError(Path . ": order must be a non-empty array.")
	Locales := LLM_Translate_LocaleNames()["locales"]
	for Code in Codes {
		if !(Code is String) || !Locales.Has(Code)
			throw ValueError(Path . ": '" . String(Code) . "' is not a locale of locale_names.json.")
	}
	Order := Candidate
	return Order
}

/**
 * The choices of the shipped files, the interface language labelled with its
 * current native name.
 * @returns {Array} Maps ("value", "label").
 */
LLM_Translate_ShippedChoices() {
	Names := LLM_Translate_LocaleNames()
	UiLabel := StrReplace(t("llm.translate.ui_language"), "{1}",
		LLM_Translate_LanguageName(I18nGetLocale(), Names))
	return LLM_Translate_Choices(Names, LLM_Translate_LocaleOrder(), LLM_Translate_Config(), UiLabel)
}

/**
 * The choices as the native parameter prompt lists them, one per line.
 * @returns {String} "<value> — <label>" lines.
 */
LLM_Translate_ChoicesText() {
	Text := ""
	for Choice in LLM_Translate_ShippedChoices()
		Text .= (Text == "" ? "" : "`n") . Choice["value"] . " — " . Choice["label"]
	return Text
}

; Throws unless Candidate holds every field the translation reads.
; @param {Map} Candidate The decoded file.
; @param {String} Path Its path, for the error.
_LLM_Translate_ValidateConfig(Candidate, Path) {
	if !(Candidate is Map)
		throw ValueError(Path . ": the root must be an object.")
	for Key in ["ui_value", "tag", "user_prefix", "prompt", "prediction_prompt"] {
		if !(Candidate.Get(Key, "") is String) || Candidate[Key] == ""
			throw ValueError(Path . ": " . Key . " must be a non-empty string.")
	}
	if !(Candidate.Get("max_language_bytes", "") is Integer) || Candidate["max_language_bytes"] < 1
		throw ValueError(Path . ": max_language_bytes must be a positive integer.")
	if !(Candidate.Get("max_tokens", "") is Integer) || Candidate["max_tokens"] <= 0
		throw ValueError(Path . ": max_tokens must be a positive integer.")
}

/**
 * Resolves a validated per-binding language; an unknown UI locale refuses.
 * @param {String} Value Stored binding target.
 * @param {Map} Config Shared configuration.
 * @param {Map} Names Shared locale names.
 * @param {String} UiLocale Current interface locale.
 * @returns {String} Language name, or "" on refusal.
 */
LLM_Translate_ResolveLanguage(Value, Config, Names, UiLocale) {
	Target := LLM_Translate_Parse(Value, Config, Names)
	if (Target == "")
		return ""
	if (Target == Config["ui_value"])
		return LLM_Translate_LanguageName(UiLocale, Names)
	KnownName := LLM_Translate_LanguageName(Target, Names)
	return (KnownName == "") ? Target : KnownName
}

/**
 * Builds a detached contextual profile without changing menu preferences.
 * @param {String} Target Per-binding target language.
 * @returns {Map|Integer} Ephemeral rewrite profile, or 0 on refusal.
 */
LLM_Translate_PredictionProfile(Target) {
	Config := LLM_Translate_Config()
	Language := LLM_Translate_ResolveLanguage(Target, Config, LLM_Translate_LocaleNames(), I18nGetLocale())
	if (Language == "")
		return 0
	return Map("id", "translate", "label", Language, "batch", false,
		"system_single", StrReplace(Config["prediction_prompt"], "{language}", Language))
}
