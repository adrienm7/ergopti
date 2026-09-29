--- _shared/lua/llm/translate.lua

--- ==============================================================================
--- MODULE: Selection Translation — Shared Lua Implementation
--- DESCRIPTION:
--- The pure logic behind the llm_translate_selection action: the selected text
--- is translated by the AI menu's current text backend and offered in the
--- prediction tooltip.
---
--- FEATURES & RATIONALE:
--- 1. The binding names the target language: "ui" (the interface language,
---    followed when the user changes it) or a locale code of
---    _shared/data/locale_names.json. Only shipped locales are accepted, so the
---    picker and the native prompt offer a closed list and a typo is refused.
--- 2. The prompt names the language by its native name ("Deutsch", "日本語"),
---    which models understand, so no second table of names is kept.
--- 3. Prompt, tag and token budget live in _shared/modules/llm/translate.json.
---
--- The AutoHotkey port is windows/modules/llm/translate.ahk. Both are pinned by
--- _shared/tests/corpus/llm/translate_vectors.json.
--- ==============================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Binding parameter =======
-- ====================================
-- ====================================

--- Parses a binding value.
--- @param value string The stored parameter.
--- @param config table Decoded translate.json.
--- @param names table Decoded locale_names.json.
--- @return string|nil target "ui" or a locale code; nil when invalid.
function M.parse(value, config, names)
	if type(value) ~= "string" then return nil end
	if value == config.ui_value then return value end
	if type(names.locales) == "table" and type(names.locales[value]) == "table" then return value end
	return nil
end

--- Reports whether a binding value is valid.
--- @param value string The stored parameter.
--- @param config table Decoded translate.json.
--- @param names table Decoded locale_names.json.
--- @return boolean
function M.is_valid(value, config, names)
	return M.parse(value, config, names) ~= nil
end

--- Returns the locale code a parsed target resolves to.
--- @param target string A value parse() accepted.
--- @param config table Decoded translate.json.
--- @param ui_locale string The interface locale code.
--- @return string code
function M.target_locale(target, config, ui_locale)
	if target == config.ui_value then return ui_locale end
	return target
end

--- Returns the native name the prompt uses for a locale.
--- @param code string A shipped locale code.
--- @param names table Decoded locale_names.json.
--- @return string|nil name Nil for an unknown code.
function M.language_name(code, names)
	local entry = type(names.locales) == "table" and names.locales[code] or nil
	return type(entry) == "table" and entry.name or nil
end

--- Returns the choices a binding may take, in display order: the interface
--- language first, then every shipped locale.
--- @param names table Decoded locale_names.json.
--- @param order table Decoded locale_order.json.
--- @param config table Decoded translate.json.
--- @param ui_label string Localized label of the interface-language choice.
--- @return table choices Array of { value, label }.
function M.choices(names, order, config, ui_label)
	local choices = { { value = config.ui_value, label = ui_label } }
	for _, code in ipairs(order.order) do
		local entry = names.locales[code]
		choices[#choices + 1] = { value = code, label = entry.flag .. " " .. entry.name }
	end
	return choices
end





-- ================================
-- ================================
-- ======= 2/ The request =========
-- ================================
-- ================================

--- Returns the system prompt for a target language.
--- @param config table Decoded translate.json.
--- @param language string Native name of the target language.
--- @return string prompt
function M.system_prompt(config, language)
	return (config.prompt:gsub("{language}", function() return language end))
end

--- Returns the user turn carrying the selection.
--- @param config table Decoded translate.json.
--- @param text string The selected text.
--- @return string text
function M.user_text(config, text)
	return config.user_prefix .. text
end

--- Extracts the translation from a raw model answer.
--- @param config table Decoded translate.json.
--- @param block string The raw model answer.
--- @return string|nil translation Nil when the tag is missing or nothing follows it.
function M.extract(config, block)
	if type(block) ~= "string" then return nil end
	local at = block:upper():find(config.tag:upper(), 1, true)
	if not at then return nil end
	local text = block:sub(at + #config.tag):gsub("%*%*", "")
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return nil end
	return text
end

return M
